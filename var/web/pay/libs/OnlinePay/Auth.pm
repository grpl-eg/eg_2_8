package OnlinePay::Auth;

use strict;
use warnings;
use base qw(OnlinePay);

use Digest::MD5 qw(md5_hex);
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use JSON::XS;
use Data::Dumper;

use OnlinePay::JSON;
use OnlinePay::Fieldmapper;

Fieldmapper->import( IDL => 'fm_IDL.xml' );

sub new {
	my $class = shift;
	my $self = {};

	my $ua = LWP::UserAgent->new;
	$ua->agent("OnlinePay::Auth ");
	$self->{_ua} = $ua;

	bless ($self, $class);
	return $self;
}

sub _ua {
	my $self = shift;
	return $self->{_ua};
}

sub user {
	my $self = shift;
	if (@_) { $self->{user} = $_[0] }
	return $self->{user};
}

sub usrid {
	my $self = shift;
	if (@_) {$self->{usrid} = $_[0] }
	return $self->{usrid};
}

sub passwd {
	my $self = shift;
	if (@_) {
		# we don't store the plaintext password
	     unless (length($_[0]) == 32) { # if we already have a 32 character password, assume it's already MD5'd
		$self->{passwd} = md5_hex($_[0]);
	     }else{
  		$self->{passwd} = $_[0];
	     }
	}
	return $self->{passwd};
}

sub gateway {
	my $self = shift;
	if (@_) {
		$self->{gateway} = $_[0];
	}
	return $self->{gateway};
	# this should be configured, not hard-coded
	#my $gateway = 'https://egtrunk.in.tcnet.org/osrf-gateway-v1';
	#return $gateway;
}

sub token {
	my $self = shift;
	if (@_) { $self->{token} = $_[0] }
	return $self->{token};
}

sub login {
	my $self = shift;
	my $type = shift || 'opac';
    my $ws = shift;

	my $seed = $self->_auth_init();
	if ($seed) {
        my $token;
		if ($ws) {
            $token = $self->_auth_complete($seed, $type, $ws);
        } else {
            $token = $self->_auth_complete($seed, $type);
        }
		if ($token) {
			$self->token($token);
			return $token;
		}
	
	}
}

sub getSession {
	my $self = shift;

	my $ua = $self->_ua();
	my $param_json = '"'.$self->token.'"';
	my $req = POST $self->gateway(), [service => 'open-ils.auth', method => 'open-ils.auth.session.retrieve', param => $param_json];
	my $res = $ua->request($req);
	if ($res->is_success) {
		my $response_obj = decode_json $res->content;
		return $response_obj->{payload}[0]->{__p};
	}

	return undef;
}

sub getSessionObj {
	my $self = shift;

	my $ua = $self->_ua();
	my $param_json = '"'.$self->token.'"';
	my $req = POST $self->gateway(), [service => 'open-ils.auth', method => 'open-ils.auth.session.retrieve', param => $param_json];
	my $res = $ua->request($req);
	if ($res->is_success) {
		my $json = $res->content;
		my $obj = OnlinePay::JSON->JSON2perl($json);
		return $obj->{payload}->[0];
	}

	return undef;
}

sub getUser {
	my $self = shift;
	my $userid = shift || $self->usrid;

	my $ua = $self->_ua();
	my $param_json = '"'.$self->token.'"';
	my $param_second = $userid;
	my $req = POST $self->gateway(), [service => 'open-ils.actor', method => 'open-ils.actor.user.fleshed.retrieve', param => $param_json, param=> $param_second];
	my $res = $ua->request($req);
	if ($res->is_success) {
		my $response_obj = decode_json $res->content;
		return $response_obj->{payload}[0]->{__p};
	}

	return undef;
}

sub _getaus {
	my $self = shift;
	my $au = $self->getUser();
	my $aus = @$au[3];
	return $aus;
}

sub _getZips {
	my $self = shift;
	my @zips;
	my $aus = $self->_getaus;
	foreach my $au (@$aus) {
		push @zips, $au->{'__p'}[8];
	}
	return \@zips;
}

sub checkZips {
	my $self = shift;
	my $goodzips = shift;
	my $usrzips = $self->_getZips();

	foreach my $usrzip (@$usrzips) {
		foreach my $goodzip (@$goodzips) {
			return 1 if $usrzip =~ /^$goodzip/;
		}
	}
	return 0;
}

sub _auth_init {
	my $self = shift;

	my $ua = $self->_ua();
	my $user = $self->user();
	my $url = $self->gateway();

	my $param_json = '"'.$user.'"';
	my $req = POST $url, [service => 'open-ils.auth', method => 'open-ils.auth.authenticate.init', param => $param_json];
	my $res = $ua->request($req);
	if ($res->is_success) {
		my $response_obj = decode_json $res->content;
		#print Dumper($response_obj);
		if ($response_obj->{status} == "200") {
			my $auth_seed = $response_obj->{payload}[0];
			return $auth_seed if $auth_seed;
		}
	} else {
		#print Dumper($res) . "\n";
	}
	return undef;
}

sub _auth_complete {
	my $self = shift;
	my $seed = shift;
    my $type = shift;
    my $ws = shift;
	my $ua = $self->_ua();
	my $url = $self->gateway();

	my $param = {
	username => $self->user(),
	password => md5_hex($seed . $self->{passwd}),
	type => $type
	};

	if ( ($self->user() =~ /^2/) && (length($self->user()) == 14) ){

		$param = {
        	barcode => $self->user(),
        	password => md5_hex($seed . $self->{passwd}),
        	type => $type
        	};

	}

    if ($ws) {
        $param->{"workstation"} = $ws;
    }

	my $param_json = encode_json $param;

	my $req = POST $url, [service => 'open-ils.auth', method => 'open-ils.auth.authenticate.complete', param => $param_json];
	my $res = $ua->request($req);
	if ($res->is_success) {
		my $response_obj = decode_json $res->content;
		#print Dumper($response_obj);
		my $auth_token = $response_obj->{payload}[0]->{payload}->{authtoken};
		#print "my auth_token is: $auth_token\n";
		return $auth_token;
	} else {
		return -1;
	}
}


1;
