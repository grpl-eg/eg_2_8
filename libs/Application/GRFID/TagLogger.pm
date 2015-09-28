package OpenILS::Application::GRFID::TagLogger;

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
    api_name => 'open-ils.grfid.taglogger.process');

sub process {
    my( $self, $conn, $auth, $reader_id, $tags) = @_;
    my $ex = new_editor(xact => 1, authtoken => $auth);
    return $ex->die_event unless $ex->checkauth;
    foreach my $t (@$tags) {
    my $r = Fieldmapper::grfid::reads->new;
                $r->reader($reader_id);
                $r->epc($t->{epc});
                $r->target_copy($t->{copy});
                $r->context($t->{context});
                $r->strength($t->{strength});
                $ex->create_grfid_reads($r) or return $ex->die_event;
    }
    $ex->commit or return $ex->die_event;
}

1;

