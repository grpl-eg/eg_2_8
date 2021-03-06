package OpenSRF::UnixServer;
use strict; use warnings;
use base qw/OpenSRF/;
use OpenSRF::EX qw(:try);
use OpenSRF::Utils::Logger qw(:level $logger);
use OpenSRF::Transport::PeerHandle;
use OpenSRF::Application;
use OpenSRF::AppSession;
use OpenSRF::DomainObject::oilsResponse qw/:status/;
use OpenSRF::System;
use OpenSRF::Utils::SettingsClient;
use Time::HiRes qw(time);
use OpenSRF::Utils::JSON;
use vars qw/@ISA $app/;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Carp;
use FreezeThaw qw/thaw/;

use IO::Socket::INET;
use IO::Socket::UNIX;

sub DESTROY { confess "Dying $$"; }

=head1 What am I

All inbound messages are passed on to the UnixServer for processing.
We take the data, close the Unix socket, and pass the data on to our abstract
'process()' method.  

Our purpose is to 'multiplex' a single TCP connection into multiple 'client' connections.
So when you pass data down the Unix socket to us, we have been preforked and waiting
to disperse new data among us.

=cut

sub app { return $app; }

{

	sub new {
		my( $class, $app1 ) = @_;
		if( ! $app1 ) {
			throw OpenSRF::EX::InvalidArg( "UnixServer requires an app name to run" );
		}
		$app = $app1;
		my $self = bless( {}, $class );
#		my $client = OpenSRF::Utils::SettingsClient->new();
#		if( $client->config_value("server_type") !~ /fork/i || 
#				OpenSRF::Utils::Config->current->bootstrap->settings_config ) {
#			warn "Calling hooks for non-prefork\n";
#			$self->configure_hook();
#			$self->child_init_hook();
#		}
		return $self;
	}

}

=head2 process_request()

Takes the incoming data, closes the Unix socket and hands the data untouched 
to the abstract process() method.  This method is implemented in our subclasses.

=cut

sub process_request {

	my $self = shift;
	my $data; my $d;
	while( $d = <STDIN> ) { $data .= $d; }

	my $orig = $0;
	$0 = "$0*";

	if( ! $data or ! defined( $data ) or $data eq "" ) {
		close($self->{server}->{client}); 
		$logger->debug("Unix child received empty data from socket", ERROR);
		$0 = $orig;
		return;
	}


	if( ! close( $self->{server}->{client} ) ) {
		$logger->debug( "Error closing Unix socket: $!", ERROR );
	}

	my $app = $self->app();
	$logger->transport( "UnixServer for $app received $data", INTERNAL );

	# --------------------------------------------------------------
	# Drop all data from the socket before coninuting to process
	# --------------------------------------------------------------
	my $ph = OpenSRF::Transport::PeerHandle->retrieve;
	if(!$ph->flush_socket()) {
		$logger->error("We received a request ".
			"and we are no longer connected to the jabber network. ".
			"We will go away and drop this request: $data");
		exit;
	}

    ($data) = thaw($data);
	my $app_session = OpenSRF::Transport->handler( $self->app(), $data );

	if(!ref($app_session)) {
		$logger->transport( "Did not receive AppSession from transport handler, returning...", WARN );
		$0 = $orig;
		return;
	}

	if($app_session->stateless and $app_session->state != $app_session->CONNECTED()){
		$logger->debug("Exiting keepalive for stateless session / orig = $orig");
		$app_session->kill_me;
		$0 = $orig;
		return;
	}


	my $client = OpenSRF::Utils::SettingsClient->new();
	my $keepalive = $client->config_value("apps", $self->app(), "keepalive");

	my $req_counter = 0;
	while( $app_session and 
			$app_session->state and 
			$app_session->state != $app_session->DISCONNECTED() and
			$app_session->find( $app_session->session_id ) ) {
		

		my $before = time;
		$logger->debug( "UnixServer calling queue_wait $keepalive", INTERNAL );
		$app_session->queue_wait( $keepalive );
		$logger->debug( "after queue wait $keepalive", INTERNAL );
		my $after = time;

		if( ($after - $before) >= $keepalive ) { 

			my $res = OpenSRF::DomainObject::oilsConnectStatus->new(
									status => "Disconnected on timeout",
									statusCode => STATUS_TIMEOUT);
			$app_session->status($res);
			$app_session->state( $app_session->DISCONNECTED() );
			last;
		}
	
	}

	my $x = 0;
	while( $app_session && $app_session->queue_wait(0) ) {
		$logger->debug( "Looping on zombies " . $x++ , DEBUG);
	}

	$logger->debug( "Timed out, disconnected, or authentication failed" );
	$app_session->kill_me if ($app_session);

	$0 = $orig;
}


sub serve {
	my( $self ) = @_;

	my $app = $self->app();
	$logger->set_service($app);

	$0 = "OpenSRF master [$app]";

	my $client = OpenSRF::Utils::SettingsClient->new();
    my @base = ('apps', $app, 'unix_config' );

	my $min_servers = $client->config_value(@base, 'min_children');
	my $max_servers = $client->config_value(@base, "max_children" );
	my $min_spare =	$client->config_value(@base, "min_spare_children" );
	my $max_spare = $client->config_value(@base, "max_spare_children" );
	my $max_requests = $client->config_value(@base, "max_requests" );
    # fwiw, these file paths are (obviously) not portable
	my $log_file = join("/", $client->config_value("dirs", "log"), $client->config_value(@base, "unix_log" ));
	my $port = join("/", $client->config_value("dirs", "sock"), $client->config_value(@base, "unix_sock" ));
	my $pid_file = join("/", $client->config_value("dirs", "pid"), $client->config_value(@base, "unix_pid" ));

    $min_spare ||= $min_servers;
    $max_spare ||= $max_servers;
    $max_requests ||= 1000;

    $logger->info("UnixServer: min=$min_servers, max=$max_servers, min_spare=$min_spare ".
        "max_spare=$max_spare, max_req=$max_requests, log_file=$log_file, port=$port, pid_file=$pid_file");

    $self->run(
        min_servers => $min_servers,
        max_servers => $max_servers,
        min_spare_servers => $min_spare,
        max_spare_servers => $max_spare,
        max_requests => $max_requests,
        log_file => $log_file,
        port => $port,
        proto => 'unix',
        pid_file => $pid_file,
    );

}


sub configure_hook {
	my $self = shift;
	my $app = $self->app;

	# boot a client
	OpenSRF::System->bootstrap_client( client_name => "system_client" );

	$logger->debug( "Setting application implementation for $app", DEBUG );
	my $client = OpenSRF::Utils::SettingsClient->new();
	my $imp = $client->config_value("apps", $app, "implementation");
	OpenSRF::Application::server_class($app);
	OpenSRF::Application->application_implementation( $imp );
	OpenSRF::Utils::JSON->register_class_hint( name => $imp, hint => $app, type => "hash" );
	OpenSRF::Application->application_implementation->initialize()
		if (OpenSRF::Application->application_implementation->can('initialize'));

	if( $client->config_value("server_type") !~ /fork/i  ) {
		$self->child_init_hook();
	}

	my $con = OpenSRF::Transport::PeerHandle->retrieve;
	if($con) {
		$con->disconnect;
	}

	return OpenSRF::Application->application_implementation;
}

sub child_init_hook { 

	$0 =~ s/master/drone/g;

	if ($ENV{OPENSRF_PROFILE}) {
		my $file = $0;
		$file =~ s/\W/_/go;
		eval "use Devel::Profiler output_file => '/tmp/profiler_$file.out', buffer_size => 0;";
		if ($@) {
			$logger->debug("Could not load Devel::Profiler: $@",ERROR);
		} else {
			$0 .= ' [PROFILING]';
			$logger->debug("Running under Devel::Profiler", INFO);
		}
	}

	my $self = shift;

#	$logger->transport( 
#			"Creating PeerHandle from UnixServer child_init_hook", INTERNAL );
	OpenSRF::Transport::PeerHandle->construct( $self->app() );
	$logger->transport( "PeerHandle Created from UnixServer child_init_hook", INTERNAL );

	OpenSRF::Application->application_implementation->child_init
		if (OpenSRF::Application->application_implementation->can('child_init'));

	return OpenSRF::Transport::PeerHandle->retrieve;
}

sub child_finish_hook {
    $logger->debug("attempting to call child exit handler...");
	OpenSRF::Application->application_implementation->child_exit
		if (OpenSRF::Application->application_implementation->can('child_exit'));
}


1;

