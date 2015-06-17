#!/usr/bin/perl

use strict; use warnings;
use diagnostics;

use lib 'libs/';

use CGI qw(:standard);
use Data::Dumper;
use POSIX qw(strftime);
use Digest::HMAC_MD5 qw(hmac_md5 hmac_md5_hex);
use JSON::XS;
use Config::Tiny;
use Template;

use OnlinePay::Auth;
use OnlinePay::Money;

my $Config = Config::Tiny->read( '/openils/conf/grpl/pay.ini' );

my $anet_login = $Config->{"authorize.net"}->{"login"};
my $anet_key = $Config->{"authorize.net"}->{"key"};
my $anet_gw = $Config->{"authorize.net"}->{"gateway"};
my $x_relay_url = $Config->{"authorize.net"}->{"x_relay_url"};
my $x_test_request = $Config->{"authorize.net"}->{"testmode"};

my $eg_gw = $Config->{"evergreen"}->{"gateway"};

my $q = CGI->new;
my $ok_to_pay = 1;
my $logged_in = 0;

my $auth = OnlinePay::Auth->new;
$auth->gateway($eg_gw);

sub show_login {
    my $err = shift;
    my $file = "pay_login.tt2";
    my $vars = {
        title => "Online Payments",
        uri => "",
	err => $err
    };

    my $template = Template->new();

    $template->process($file, $vars)
        || die "Template failed: ", $template->error(), "\n";
}

sub check_login {
	my $user = shift;
	my $pass = shift;
	$auth->user($user);
	$auth->passwd($pass);

	my $token = $auth->login;
	if (!$token) {
		#print $q->p("<h2 style='color: red;'> Login Failed </h2>");
		show_login("Login Failed");
	} else {
        $logged_in = 1;
    }
}

sub check_ses {
    my $ses = shift;
    $auth->token($ses);
    if ($auth->getSession()) {
        $logged_in = 1;
    } else {
        #print $q->p("<h2 style='color: red;'> Bad session token.</h2>");
	show_login("Bad session token");
    }
}

sub show_xacts {
	my $usr = $auth->getSession()->[28];

	my $money = OnlinePay::Money->new($auth->token);
	$money->gateway( $eg_gw );

	my ($balance, $owed, $paid) = $money->getSummary($usr);

	my $xacts = $money->getXacts($usr);

	my $good = [ grep { $_->{balance} !~ /^-/; } @$xacts ];

	if (@$good != @$xacts) {
        # sorry, we owe you!
        $ok_to_pay = 0;
	}

	my $good_balance = 0;
	map { $good_balance += $_->{balance} } @$good;


	if ( abs($balance - $good_balance) > 0.01 ) {
        # sorry, something doesn't quite add up here... 
        $ok_to_pay = 0;
	}

    my @payable;
    my @unpayable;

    map {
        if ($_->{payable}) {
            push @payable, $_;
        } else {
            push @unpayable, $_;
        }
    } @$xacts;

    my $payable_balance = 0;
	map { $payable_balance += $_->{balance} } @payable;
    $payable_balance = sprintf("%.2f", $payable_balance);

	my @lineitems;
	my @xact_ids;
	map {
		my $delim = '<|>';
        # authorize.net lineitem fields are:
        # id, name, description, quantity, price, taxable
		my $lineitem = join($delim, $_->{id},$_->{type},"",1,$_->{balance},0);
		push @lineitems, $lineitem;
		push @xact_ids, $_->{id};

	} @payable;

    my $anet_form = &return_anet_form($payable_balance, \@lineitems, \@xact_ids, $usr);

    my $template = Template->new();
    my $file = "pay_payments.tt2";
    my $vars = {
        title => "Online Payments",
        xacts => \@payable,
        unpayable_xacts => \@unpayable,
        ok_to_pay => $ok_to_pay,
        balance => $payable_balance,
        form => $anet_form
    };

    $template->process($file, $vars)
        || die "Template failed: ", $template->error(), "\n";

}

sub check_ok_to_pay {
	
}

sub return_anet_form {
	my $amount = shift;
	my $lineitems = shift;
	my $xact_ids = shift;
    my $usr = shift;

    my $form;

	my $invoice = strftime "%Y%m%d%H%M%S", localtime;
	my $sequence = int(rand(1000));
	my $timestamp = time();
	my $description = "Payment on patron account";
	my $xact_ids_json = encode_json $xact_ids;
	my $fingerprint = hmac_md5_hex($anet_login . "^" . $sequence . "^" . $timestamp . "^" . $amount . "^", $anet_key);

	$form = $q->start_form(-method=>"POST", -id=>'form1', -name=>'form1', -action=>$anet_gw, -enctype=>&CGI::URL_ENCODED );
	$form .= $q->hidden(-name=>"x_login", -value=>$anet_login). "\n".
        $q->hidden(-name=>"x_cust_id", -value=>$usr). "\n".
        $q->hidden(-name=>"x_amount", -id=>"x_amount", -value=>$amount). "\n".
        $q->hidden(-name=>"x_description", -value=>$description). "\n".
        $q->hidden(-name=>"xact_list", -id=>"xact_list", -value=>$xact_ids_json). "\n".
        $q->hidden(-name=>"x_invoice_num", -value=>$invoice). "\n".
        $q->hidden(-name=>"x_fp_sequence", -id=>"x_fp_sequence", -value=>$sequence). "\n".
        $q->hidden(-name=>"x_fp_timestamp", -id=>"x_fp_timestamp", -value=>$timestamp). "\n".
        $q->hidden(-name=>"x_fp_hash", id=>"x_fp_hash", -value=>$fingerprint). "\n".
        $q->hidden(-name=>"x_test_request", -value=>$x_test_request). "\n".
        $q->hidden(-name=>"x_show_form", -value=>"PAYMENT_FORM"). "\n".
        $q->hidden(-name=>"x_version", -value=>"3.1"). "\n".
        $q->hidden(-name=>"x_relay_response", -value=>"true"). "\n".
        $q->hidden(-name=>"x_relay_url", -value=>$x_relay_url). "\n";

	foreach my $lineitem (@$lineitems) {
		$form .= $q->hidden(-name=>"x_line_item", -id=>"items", -value=>$lineitem). "\n";
	}	

	$form .= $q->button(-name=>'', id=>'payButton', -value=>"Pay Online", -onClick=>'submitIt()'). $q->endform;

    return $form;

}

sub main {
	print header;

	my $user = param('user');
	my $pass = param('pass');
	my $ses = param('ses');

	if ( $user && $pass ) {
		&check_login( $user, $pass );
	} else {
		if ($ses) {
            &check_ses( $ses );
        } else {
            &show_login( );
        }
	}

    if ($logged_in) {
        &show_xacts;
    }

}

&main();
