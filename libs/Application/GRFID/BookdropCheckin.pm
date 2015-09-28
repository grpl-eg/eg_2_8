package OpenILS::Application::GRFID::BookdropCheckin;

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
    api_name => 'open-ils.grfid.bookdropcheckin.process');

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
    )->[0] or return "Reader Config Error";

    my $svc_opts = $e->json_query(
    {
            "from" => { "grfsvo" => {"grfsv" => {}}},
            "where" => { "+grfsv" => {"name" => "BookdropCheckin"}},
    })->[0];

    openlog("GRFID BookdropCheckin", '', $svc_opts->{syslog_facility}) if $svc_opts->{syslog_facility};

    foreach my $t (@$tags) { # %t keys: reader,copy,epc,context,strength
	next  unless $t->{copy} =~ /^\d+$/;
	my $tlb = $e->json_query({ from => ['grfid.tlb_copy_info', $t->{copy}] })->[0];
	my $stamp = `date --rfc-3339=seconds`;
	$stamp = scalar reverse $stamp;
	my $junk;
	($junk,$stamp) = split(/-/,$stamp,2); # split off timezone
    	$stamp = scalar reverse $stamp;
	$logger->warn("BookdropCheckin: $rdr_opts->{hold_as_transit} $rdr_opts->{auto_print} $stamp $rdr_opts->{rssi} $rdr_opts->{process_delay} testmode is: $rdr_opts->{testmode}");
    	##  Bail out if this copy is not a status we want to checkin
    	my $s = $e->json_query({ from => ['grfid.singulate_bookdrop_checkin_test', $t->{copy}, $reader_id] })->[0]->{copy_status};
	$logger->warn("Status for $t->{copy} from grfid singulate is: $s");
    	next unless defined $s;
    	next unless ( $s != 102 && $s != 13 && $s != 104);

        my $result = {
                copyId    => $t->{copy},
                exception => 'None',
                success   => 0,
                message   => '',
                title     => $tlb->{title},
                barcode   => $tlb->{barcode},
                callnumber=> $tlb->{call},
        };


    	if ($U->is_true($rdr_opts->{testmode})) {
		$result->{message} = "SUCCESS";
		$result->{exception} = "testMode";
		$result->{success} = 1;
		$result->{title} = "TestMode - copy ($t->{copy})";
    	} else { # not testmode so call checkin
        	my $circ = OpenSRF::AppSession->create('open-ils.circ')
            	->request('open-ils.circ.checkin.override', $auth, { copy_id => $t->{copy}, hold_as_transit => $U->is_true($rdr_opts->{hold_as_transit}) })->gather;

        	$result->{message} = $circ->{textcode};
        	if ($circ->{textcode} eq 'PERM_FAILURE') {
                	$result->{message} = $circ->{ilsperm};
                	$result->{exception} = "CheckinFailure";
			$result->{title} = $tlb->{title};
			$result->{barcode} = $tlb->{barcode};
			$result->{callnumber} = $tlb->{call};
        	} elsif ($result->{message} eq 'NO_SESSION') {
            		last;
        	} else { # pull hold and transit info
	 		if ( $circ->{textcode} eq 'SUCCESS' ) {
                		$result->{success} = 1;
            		}
            		my $c = new Fieldmapper::action::circulation($circ->{payload}->{circ});
            		$result->{circ_id} = $c->id;
            		my $ahr = new Fieldmapper::action::hold_request($circ->{payload}->{hold});
            		my $acp = new Fieldmapper::asset::copy($circ->{payload}->{copy});

            		if ($acp->status == 8) {
                		my $val = $ahr->usr;
            			my $hname = $e->json_query(
                  		{
                        	  select => { au => ['family_name', 'first_given_name', 'alias'] },
                        	  from =>  'au',
                        	  where => { id => $val },
                  		}
            			)->[0];
				$result->{message} = "$hname->{family_name}, " .  substr($hname->{first_given_name},0,2);
				$result->{message} = $hname->{alias} if $hname->{alias};
                		$result->{exception} = 'hold';
				my $hreceipt = $U->simplereq( 'open-ils.grfid', 'open-ils.grfid.receiptprint.hold', $result->{message},substr($ahr->shelf_expire_time,0,10),$tlb->{title},$tlb->{barcode},substr($tlb->{call},0,25),$stamp,$rdr_opts->{receipt_printer}) if $U->is_true($rdr_opts->{auto_print});
            		}

            		if ($result->{message} =~ /ROUTE/) {

				my $dx = new_editor(xact => 1, authtoken => $auth);
                        	my $dst = $dx->json_query(
                        	{
                          	  select => { atc => ['dest'] },
                          	  from =>  'atc',
                          	  where => { dest_recv_time => undef, target_copy => $t->{copy}},
                        	})->[0]->{dest};
                        	$dx->rollback;

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
                		my $treciept = $U->simplereq('open-ils.grfid', 'open-ils.grfid.receiptprint.transit',$result->{message},$result->{title},$result->{barcode},substr($result->{callnumber},0,25),$stamp,$rdr_opts->{receipt_printer}) if $U->is_true($rdr_opts->{auto_print});
            		} # end if ROUTE


            			if ($acp->alert_message =~ /new media/i) { # New AV
					my $nmreceipt =  $U->simplereq('open-ils.grfid', 'open-ils.grfid.receiptprint.newmedia', "New Media",$result->{barcode},substr($result->{callnumber},0,25),$stamp,$rdr_opts->{receipt_printer}) if $U->is_true($rdr_opts->{auto_print});
            			}

                        	if ($acp->alert_message) {
					$result->{message} .= " ". $acp->alert_message;
                        	}

        		} # end pull hold and transit info

   	} # end not testmode so call checkin
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
}

1;
