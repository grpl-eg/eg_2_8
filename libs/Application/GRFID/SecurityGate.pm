package OpenILS::Application::GRFID::SecurityGate;

use strict;
use warnings;

use OpenILS::Application;
use base qw/OpenILS::Application/;
use OpenSRF::AppSession;
use OpenSRF::Utils::Logger qw($logger);
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Application::AppUtils;
use OpenILS::Utils::Fieldmapper;

my $U = 'OpenILS::Application::AppUtils';

__PACKAGE__->register_method(
    method => 'process',
    authoritative => 1,
    api_name => 'open-ils.grfid.securitygate.process');

sub process {
    my( $self, $conn, $auth, $reader_id, $tags) = @_;
    my $e = new_editor(authtoken => $auth);
    my $ex = new_editor(xact => 1, authtoken => $auth);
    return $e->die_event unless $e->checkauth;
    my $org_id = $e->requestor->ws_ou;
    my $whitelist = 'Checked out Discard/Weed Damaged';

    my $svc_opts = $e->json_query(
    {
            "from" => { "grfsvo" => {"grfsv" => {}}},
            "where" => { "+grfsv" => {"name" => "SecurityGate"}},
    })->[0];

    foreach my $t (@$tags) {
	my $tlb = $e->json_query({ from => ['grfid.tlb_copy_info', $t->{copy}] })->[0];
	if ($whitelist !~ $t->{status}) { # should make this a service option in DB
    		my $g = Fieldmapper::grfid::gate_alerts->new;
                  $g->reader_id($reader_id);
                  $g->epc($t->{epc});
                  $g->copy_id($t->{copy});
                  $g->copy_status($t->{status});
                  $g->title($tlb->{title});
                  $g->barcode($tlb->{barcode});
                  $g->callnumber($tlb->{call});
                  $g->org_unit_id($org_id);
                  $ex->create_grfid_gate_alerts($g) or return $e->die_event;
    	}
    }
    $ex->commit or return $e->die_event;
}

1;
