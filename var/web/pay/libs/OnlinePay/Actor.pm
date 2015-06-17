package OnlinePay::Money;

use strict;
use warnings;
use base qw(OnlinePay);

use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use JSON::XS;
use Data::Dumper;

use OnlinePay::Fieldmapper;

Fieldmapper->import( IDL => 'fm_IDL.xml' );

sub new {
	my $class = shift;
	my $self = {};

	my $ua = LWP::UserAgent->new;
	$ua->agent("OnlinePay::Money ");
	$self->{_ua} = $ua;

	bless ($self, $class);
	return $self;
}

sub _ua {
	my $self = shift;
	return $self->{_ua};
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

sub _get_mous {
	my $self = shift;
	my $token = shift;
	my $usr = shift;
	
	my $ua = $self->_ua();

	my $param_json = '"'.$token.'"';
	my $req = POST $self->gateway(), [service => 'open-ils.actor', method => 'open-ils.actor.user.fines.summary', param => $param_json, param => $usr];
	my $res = $ua->request($req);
	if ($res->is_success) {
		my $response_obj = decode_json $res->content;
		return $response_obj->{payload}[0]->{__p};
	}

	return undef;
}

sub getSummary {
	my $self = shift;
	my $token = shift;
	my $usr = shift;

	my $mous = $self->_get_mous($token, $usr);

	my ($balance, $owed, $paid) = @$mous[3..5];
	
	return ($balance, $owed, $paid);
}

sub _get_xacts {
	my $self = shift;
	my $token = shift;
	my $usr = shift;
	
	my $ua = $self->_ua();

	my $param_json = '"'.$token.'"';
	my $req = POST $self->gateway(), [service => 'open-ils.actor', method => 'open-ils.actor.user.transactions.have_balance.fleshed', param => $param_json, param => $usr];
	my $res = $ua->request($req);
	if ($res->is_success) {
		my $obj = OnlinePay::JSON->JSON2perl( $res->content );
		#print Dumper($obj);
		return $obj->{payload}[0];
		#my $response_obj = decode_json $res->content;
		#print Dumper($response_obj);
		#return $response_obj->{payload}[0];
	}

	return undef;
}

sub getXacts {
	my $self = shift;
	my $token = shift;
	my $usr = shift;

	my $xacts = $self->_get_xacts($token, $usr);

	my @xacts_to_return;

	map { 
		my %x;
		my $xact_type = $_->{transaction}->xact_type;
		$x{id} = $_->{transaction}->id;
		$x{type} = $_->{transaction}->last_billing_type;
		$x{balance} = $_->{transaction}->balance_owed;
		$x{xact_start} = $_->{transaction}->xact_start;
		if ($xact_type eq 'grocery') {
			$x{descr} = '';
			#$x{descr} = $_->{transaction}->last_billing_note;
		} else {
			$x{descr} = $_->{record}->title;
		}
		push @xacts_to_return, \%x;
	} (@$xacts);

	return \@xacts_to_return;
}

sub payXacts {
	my $self = shift;
	my $token = shift;
	my $usr = shift;
	my $xacts = shift;

	
}

1;
