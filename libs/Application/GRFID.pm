package OpenILS::Application::GRFID;

use strict;
use warnings;

use OpenILS::Application;
use base qw/OpenILS::Application/;
use OpenSRF::AppSession;
use OpenSRF::Utils::Logger qw($logger);
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Application::AppUtils;

use OpenILS::Application::GRFID::TagLogger;
use OpenILS::Application::GRFID::BookdropCheckin;
use OpenILS::Application::GRFID::ReceiptPrint;
use OpenILS::Application::GRFID::CartReader;
use OpenILS::Application::GRFID::SecurityGate;

my $U = 'OpenILS::Application::AppUtils';
my $e;

__PACKAGE__->register_method(
    method => 'dispatch',
    api_name => 'open-ils.grfid.dispatch');

sub dispatch {
	my( $self, $conn, $auth, $reader_id, $tags ) = @_;
	$e = new_editor(authtoken => $auth);

	my $rfid_services = $e->json_query(
        {
            "select" => {"grfsv" => ["name", "id"], "grfsvm" => ["dispatch_order"]},
            "from" => { "grfsv" => {"grfsvm" => {}}},
            "where" => { "+grfsvm" => {"reader" => $reader_id}},
            "order_by" => {"grfsvm" => ["dispatch_order"]}
        }
	) or return "dispatch found no service config";

	foreach my $s (@$rfid_services) {
                my $service_name = lc $s->{name};
		$logger->warn("calling open-ils.grfid, open-ils.grfid.$service_name.process, $auth, $reader_id, $tags");
                my $result = $U->simplereq( "open-ils.grfid", "open-ils.grfid.$service_name.process", $auth, $reader_id, $tags);
		my $service_id = $s->{id};
		my $delay = get_service_process_delay($service_id);
		sleep($delay);
	}
} # end dispatch

sub get_service_process_delay {
	my $service = shift;
	my $spd = $e->json_query(
        {
            select => {'grfsvo' => ['process_delay']},
            from =>  'grfsvo',
            where => { service => $service },
        }
	);
	return $spd->[0]->{process_delay} || 0;
} # end get_service_process_delay
1;
