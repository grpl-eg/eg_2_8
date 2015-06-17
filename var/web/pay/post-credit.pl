#!/usr/bin/perl

use strict;
use warnings;

use lib 'libs/';

use Config::Tiny;
use Getopt::Std;
use JSON::XS;
use Data::Dumper;

use OnlinePay::Auth;
use OnlinePay::Money;

my $Config = Config::Tiny->read( '/openils/conf/grpl/post.ini' );

my $coder = JSON::XS->new->ascii;

my %args;
getopt('vf:', \%args);

my $file = $args{'f'};
my $verbose = $args{'v'};

my $gateway = $Config->{"evergreen"}->{"gateway"};
my $user = $Config->{"evergreen"}->{"user"};
my $pass = $Config->{"evergreen"}->{"pass"};
my $ws = $Config->{"evergreen"}->{"ws"};

my $auth = OnlinePay::Auth->new;
$auth->gateway($gateway);
$auth->user($user);
$auth->passwd($pass);

my $token = $auth->login('staff', $ws);
die ("unable to log in!\n") if (!$token);

my $money = OnlinePay::Money->new($token);
$money->gateway( $gateway );


open my $FILE, "$file" if ($file) or die("unable to open specified file, or no file specified!\n");

my $file_contents = do { local $/; <$FILE> };

close $FILE;

my $payment_to_post = $coder->decode($file_contents);

my $lx = $money->get_last_xact($payment_to_post->{"x_cust_id"});

my $pay = {};
$pay->{"payment_type"} = "credit_card_payment";
$pay->{"userid"} = $payment_to_post->{"x_cust_id"};
$pay->{"note"} = "Online " . $payment_to_post->{"x_invoice_num"};

if ($payment_to_post->{"x_method"} eq 'ECHECK'){
	$payment_to_post->{"x_auth_code"} = '1111';
}

my $cc = {};
$cc->{"approval_code"} = $payment_to_post->{"x_auth_code"};
$cc->{"cc_type"} = '';
$cc->{"cc_number"} = '';
$cc->{"expire_month"} = 0;
$cc->{"expire_year"} = 0;

$pay->{"cc_args"} = $cc;


my @xacts;
my $working_balance = $payment_to_post->{"x_amount"};
print "starting balance: $working_balance\n" if $verbose;
map {
    unless ($_ =~ /^1111/){
    my $xact = $money->getSingleXact($_);
    #print Dumper($xact);
    my $balance_owed = $xact->balance_owed;
    #print "owed: ", $balance_owed, "\n";
    if ($balance_owed == 0) {
        die("zero balance -- already paid?\n");
    }
    $working_balance = ($working_balance-$balance_owed);
    push @xacts, [$_, $balance_owed];
    }else{
	$_ =~ s/^1111//;
	#push @xacts, [undef,"$_.00"];
	$pay->{"patron_credit"} = "$_.00";
    }
} @{$payment_to_post->{"xact_list"}};

if ( abs($working_balance) > 0.01 ) {
#    die("unbalanced payment. difference of $working_balance -- aborting!\n");
}

$pay->{"payments"} = \@xacts;

print JSON::XS->new->ascii->pretty->encode($pay);

$money->payment(JSON::XS->new->ascii->encode($pay),$lx);

my $newfile = $file;
$newfile =~ s/payment/done-payment/;
#system "/bin/mv $file $newfile";

