package OpenILS::Application::GRFID::CartReader;

use strict;
use warnings;

use OpenILS::Application;
use base qw/OpenILS::Application/;
use OpenSRF::AppSession;
use OpenSRF::Utils::Logger qw($logger);
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Application::AppUtils;
use OpenILS::Utils::Fieldmapper;
use OpenILS::Application::GRFID::ReceiptPrint;

my $U = 'OpenILS::Application::AppUtils';

my $dbh;

my %loc=(
        '10'    => 'GRPL-GR',
        '11'    => 'GRPL-GM',
        '12'    => 'GRPL-GO',
        '13'    => 'GRPL-GS',
        '14'    => 'GRPL-GC',
        '15'    => 'GRPL-GN',
        '16'    => 'GRPL-GW',
        '17'    => 'GRPL-GY'
);


__PACKAGE__->register_method(
    method => 'process',
    authoritative => 1,
    api_name => 'open-ils.grfid.cartreader.process');

sub process {
    my( $self, $conn, $auth, $reader_id, $tags) = @_;
    my @results = ();
    my $payload = { results => \@results };
    my $e = new_editor(authtoken => $auth);
    my $org_id;

    if(!$org_id) {
        return $e->event unless $e->checkauth;
        $org_id = $e->requestor->ws_ou;
    }

    my $rdr_opts = $e->json_query(
        {
            from =>  'grfro',
            where => { reader => $reader_id},
        }
        )->[0] or return "No reader options $reader_id";

    my $svc_opts = $e->json_query(
    {
            "from" => { "grfsvo" => {"grfsv" => {}}},
            "where" => { "+grfsv" => {"name" => "CartReader"}},
    })->[0];

    my $tlb = {};

    my $stamp = `date --rfc-3339=seconds`;
    $stamp = scalar reverse $stamp;
    my $junk;
    ($junk,$stamp) = split(/-/,$stamp,2); # split off timezone
    $stamp = scalar reverse $stamp;

    foreach my $t (@$tags) { # %t keys: reader,copy,epc,context,strength
        next  unless $t->{copy} =~ /^\d+$/; # if it is not all digits its not a GRPL item tag
	$tlb = $e->json_query({ from => ['grfid.tlb_copy_info', $t->{copy}] })->[0];

	$logger->warn("Cart Reader: $tlb->{barcode} $t->{copy} $rdr_opts->{hold_as_transit} $rdr_opts->{auto_print} $stamp $rdr_opts->{rssi} $rdr_opts->{process_delay} testmode is: $rdr_opts->{testmode}");

	##  Bail out if this copy is not a status we want to checkin
	my $jq = $e->json_query({ from => ['grfid.singulate_cartreader_test', $t->{copy}, $reader_id] })->[0];
	my $s = $jq->{copy_status};
	my $rid = $jq->{reads_id};
	$logger->warn("Status from grfid singulate is: $s");
	if ( defined $s ) { # check all singulated items for New Media alert
		if ($tlb->{alert_message} =~ /new media/i) { # New AV
			my $nmreceipt =  $U->simplereq('open-ils.grfid', 'open-ils.grfid.receiptprint.newmedia', "New Media",$tlb->{barcode},substr($tlb->{call},0,25),$stamp,$rdr_opts->{receipt_printer}) if $U->is_true($rdr_opts->{auto_print});
        	}
		my $gr = $e->retrieve_grfid_reads($rid);
		$gr->context('Cartreader singulated');
		my $ex = new_editor(xact => 1, authtoken => $auth);
		$ex->update_grfid_reads($gr);
		$ex->commit;
	}
	next unless ($s == 1  || $s == 6); # only do checkin for items in route or that did not get checked in by the bookdrop

	my $result = {
		copyId    => $t->{copy},
		exception => 'None',
		success   => 0,
		message   => '',
 		title     => $tlb->{title},
                barcode   => $tlb->{barcode},
                callnumber=> $tlb->{call},
	};

	if ($U->is_true($rdr_opts->{testmode})) { # if testmode set test info as result
		$result->{exception} = "testmode";
		$result->{success} = 1;
		$result->{title} = "TestMode - $result->{title}";

	} else { # not testmode so call circ.checkin
        	my $circ = OpenSRF::AppSession->create('open-ils.circ')
                ->request('open-ils.circ.checkin.override', $auth, { copy_id => $t->{copy}, hold_as_transit => $U->is_true($rdr_opts->{testmode}) })->gather;
        	$result->{message} = $circ->{textcode};

		if ($circ->{textcode} eq 'PERM_FAILURE') {
                	$result->{message} = $circ->{ilsperm};
                	$result->{exception} = "CheckinFailure";
        	} elsif ($result->{message} eq 'NO_SESSION') {
            		last;
        	} else { # pull circ and hold info
                        if ( $circ->{textcode} eq 'SUCCESS' ) {
                                $result->{success} = 1;
                        }
            		my $c = new Fieldmapper::action::circulation($circ->{payload}->{circ});
            		$result->{circ_id} = $c->id;
            		my $ahr = new Fieldmapper::action::hold_request($circ->{payload}->{hold});
			my $acp = new Fieldmapper::asset::copy($circ->{payload}->{copy});

            		if ($acp->status == 8) { # status on hold
                		my $val = $ahr->usr;
            			my $hname = $e->json_query(
                  		{
                        	  select => { au => ['family_name', 'first_given_name', 'alias'] },
                        	  from =>  'au',
                        	  where => { id => $val },
                  		})->[0];
				$result->{message} = "$hname->{family_name}, " . substr($hname->{first_given_name},0,2);
				$result->{message} = $hname->{alias} if $hname->{alias};
                		$result->{exception} = 'hold';
				my $hreceipt = $U->simplereq( 'open-ils.grfid', 'open-ils.grfid.receiptprint.hold', $result->{message},substr($ahr->shelf_expire_time,0,10),$tlb->{title},$tlb->{barcode},substr($tlb->{call},0,25),$stamp,$rdr_opts->{receipt_printer}) if $U->is_true($rdr_opts->{auto_print});
            		} # end status on hold

			my $dx = new_editor(xact => 1, authtoken => $auth);
			my $dst = $dx->json_query(
                        {
                          select => { atc => ['dest'] },
                          from =>  'atc',
                          where => { dest_recv_time => undef, target_copy => $t->{copy}},
                        })->[0]->{dest};
			$dx->rollback;
			
            		if ($dst) {
				my $hx = new_editor(xact => 1, authtoken => $auth);
            			my $hold = $hx->json_query(
                		{
                        	  select => { ahtc => ['id'] },
                        	  from =>  'ahtc',
                        	  where => { dest_recv_time => undef, target_copy => $t->{copy}},
                		})->[0]->{id};
				$hx->rollback;

                		$result->{message} = $loc{$dst};
                		$result->{exception} = 'transit';

                		if ($hold) {
                        		$result->{exception} = 'transitHold';
                        		$result->{message} .= "   ...   HOLD";
                		}
				$logger->warn("calling grfid.receiptprint.transit");
                		my $treciept = $U->simplereq('open-ils.grfid', 'open-ils.grfid.receiptprint.transit',$result->{message},$result->{title},$result->{barcode},substr($result->{callnumber},0,25),$stamp,$rdr_opts->{receipt_printer}) if $U->is_true($rdr_opts->{auto_print});
            		} # end if $dst

            		if ($acp->alert_message) {
				$result->{message} .= " ". $acp->alert_message;
            		}

        	} # end pull circ and hold info
	} # end else not testmode so call circ.checkin

	my $cx = new_editor(xact => 1, authtoken => $auth);
   	my $bc = Fieldmapper::grfid::bookdrop_checkins->new;
	$bc->copy_id($t->{copy});
	$bc->title($result->{title});
	$bc->barcode($result->{barcode});
	$bc->callnumber($result->{callnumber});
	$bc->reader_id($reader_id);
	$bc->org_unit_id($org_id);
	$bc->exception($result->{exception});
	$bc->message($result->{message});
	$bc->circ_id($result->{circ_id});
    	$cx->create_grfid_bookdrop_checkins($bc);
	$cx->commit or return $cx->die_event;
    } # end foreach tag
} # end sub process

1;
