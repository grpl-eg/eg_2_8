#!/usr/bin/perl -w

use Template;

print "Content-type: text/html \n\n";

my $t = localtime(time);

    my $file = "pay_receipt.tt2";
    my $vars = {
        title => "Online Payment Receipt",
        trans_id => 12345,
        amount => '5.00',
        invoice => 12345,
        cust_id => 11111,
	description => 'Overdue fines',
	time => $t
    };

    my $template = Template->new();

    $template->process($file, $vars)
        || die "Template failed: ", $template->error(), "\n";

