package OpenILS::Application::GRFID::ReceiptPrint;

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
    method => 'hold',
    authoritative => 1,
    api_name => 'open-ils.grfid.receiptprint.hold');

sub hold {
    my( $self, $conn, $name, $xpdate, $title, $bc, $cn, $stamp, $rp) = @_;
$logger->warn("open-ils.grfid.receiptprint.hold self, $name, $xpdate, $title, $bc, $cn, $stamp, $rp");
        my $l4 = substr($bc, -4);
        my $at=chr(0);
        open FH, ">/tmp/$xpdate-$bc" or die $!;
        print FH $at.chr(29).chr(33).chr(17);
        print FH "$name\n";
        print FH "$xpdate\n";
        print FH chr(27).chr(64);
        print FH "\n\n\n\n\n\n";
        print FH "$cn\n";
        print FH "$title - $l4\n$stamp";
        print FH "\n\n\n\n\n\n\n\n\n\n\n\n\n\n";
        print FH $at."\n".chr(29)."VB".$at.$at.$at.$at;
        close FH;
        system "cat /tmp/$xpdate-$bc | netcat $rp 9100";
}

__PACKAGE__->register_method(
    method => 'transit',
    authoritative => 1,
    api_name => 'open-ils.grfid.receiptprint.transit');

sub transit {
        my ($self,$conn,$dest,$title,$bc,$cn,$stamp,$rp) = @_;
$logger->warn("open-ils.grfid.receiptprint.transit $dest,$title,$bc,$cn,$stamp,$rp");
        my $at=chr(0);
        open FH, ">/tmp/transit-$bc" or die $!;
        print FH $at.chr(29).chr(33).chr(17);
        print FH "$dest\n\n";
        print FH chr(27).chr(64);
        print FH "$cn\n";
        print FH "$title\n";
        print FH "$bc\n";
        print FH "\n\n\n\n\n\n";
        print FH "$stamp";
        print FH "\n\n\n\n\n\n\n\n\n\n\n\n\n\n";
        print FH $at."\n".chr(29)."VB".$at.$at.$at.$at;
        close FH;
        system "cat /tmp/transit-$bc | netcat $rp 9100";
}

__PACKAGE__->register_method(
    method => 'newmedia',
    authoritative => 1,
    api_name => 'open-ils.grfid.receiptprint.newmedia');

sub newmedia {
        my ($self,$conn,$msg,$bc,$cn,$stamp,$rp) = @_;
$logger->warn("open-ils.grfid.receiptprint.newmedia $msg,$bc,$cn,$stamp,$rp");
        my $at=chr(0);
        open FH, ">/tmp/newav-$bc" or die $!;
        print FH $at.chr(29).chr(33).chr(17);
        print FH "$msg\n\n";
        print FH chr(27).chr(64);
        print FH "$cn\n";
        print FH "$bc\n";
        print FH "\n\n\n\n\n\n";
        print FH "$stamp";
        print FH "\n\n\n\n\n\n\n\n\n\n\n\n\n\n";
        print FH $at."\n".chr(29)."VB".$at.$at.$at.$at;
        close FH;
        system "cat /tmp/newav-$bc | netcat $rp 9100";
}

1;

