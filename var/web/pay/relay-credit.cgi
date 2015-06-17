#!/usr/bin/perl

use strict;
use warnings;

use lib 'libs/';

use CGI qw/:standard -no_xhtml/;
use Data::Dumper;
use POSIX qw(strftime);
use Digest::MD5 qw(md5_hex);
use Template;

use JSON::XS;
use Config::Tiny;

# This shall be called by authorize.net and needs to both return output to the
# user and log successful transactions for later batching into Evergreen
#
# needs to log: IP, invoice, response code(s), json xact_ids, amount
#

my $Config = Config::Tiny->read( '/openils/conf/grpl/relay.ini' );

# relay secret and API login are used to authenticate response from authorize.net 
my $relay_secret = $Config->{"authorize.net"}->{"relay_secret"};
my $anet_login = $Config->{"authorize.net"}->{"login"};
my $queue_dir = $Config->{"authorize.net"}->{"queue_dir"};

my $q = CGI->new;

# our payment object -- will be a hashref
my $pay;

sub parse_anet_relay {
    my $obj = {};
    $obj->{"x_trans_id"} = $q->param('x_trans_id');
    $obj->{"x_amount"}   = $q->param('x_amount');
    if ($obj->{"x_amount"} =~ /(.*\.\d\d)00/) {
        $obj->{"x_amount"} = $1;
    }
    $obj->{"x_response_code"} = $q->param('x_response_code'); 
    $obj->{"x_response_subcode"} = $q->param('x_response_subcode'); 
    $obj->{"x_response_reason_code"} = $q->param('x_response_reason_code'); 
    $obj->{"x_auth_code"} = $q->param('x_auth_code'); 
    $obj->{"x_avs_code"} = $q->param('x_avs_code'); 
    $obj->{"x_invoice_num"} = $q->param('x_invoice_num'); 
    $obj->{"x_description"} = $q->param('x_description'); 
    $obj->{"x_method"} = $q->param('x_method'); 
    $obj->{"x_type"} = $q->param('x_type'); 
    $obj->{"x_cust_id"} = $q->param('x_cust_id'); 
    $obj->{"x_MD5_Hash"} = $q->param("x_MD5_Hash");
    $obj->{"x_test_request"} = $q->param("x_test_request");
    $obj->{"x_cvv2_resp_code"} = $q->param("x_cvv2_resp_code");
    $obj->{"xact_list"} = decode_json( $q->param('xact_list') );
    $obj->{"is_valid"} = &verify_hash($obj);
    $obj->{"is_success"} = &verify_success($obj);
    $obj->{"user_agent"} = $q->user_agent();
    $obj->{"remote_ip"} = $q->remote_host();
    $obj->{"referer"} = $q->referer();
    $obj->{"request_method"} = $q->request_method();

    return $obj;

}

sub verify_hash {
    my $pay = shift;

    my $hash_input = $relay_secret . $anet_login . $pay->{"x_trans_id"} . $pay->{"x_amount"};
    my $shouldhash = md5_hex($hash_input);
    my $relayed_hash = $pay->{"x_MD5_Hash"};

    if ( lc($relayed_hash) eq lc($shouldhash) ) {
        return 1;
    }

    return 0;
}

sub verify_success {
    my $pay = shift;

    if ( $pay->{x_response_code} == 1 ) {
        return 1;
    }

    return 0;
}

sub save_queue_file {
    my $pay_to_save = shift;
    my $pay_json = JSON::XS->new->ascii->encode($pay_to_save);
    my $queue_file = $queue_dir ."/payment_". $pay->{"x_invoice_num"} ."_". $$ . ".json";
    #print $queue_file;
    open my $FILE, ">$queue_file";
    print $FILE $pay_json, "\n";
    close($FILE);
    return $queue_file;
}

sub show_receipt {

    my $tlist = $q->param('xact_list');
    $tlist =~ s/\"//g;
    $tlist =~ s/\[//;
    $tlist =~ s/\]//;
    my $file = "pay_receipt.tt2";
    my $vars = {
        title => "Online Payment Receipt",
        trans_id => $tlist,
        amount => $pay->{'x_amount'},
        invoice => $pay->{'x_invoice_num'},
        cust_id => $pay->{'x_cust_id'},
	description => $pay->{'x_description'},
    };

    my $template = Template->new();

    $template->process($file, $vars)
        || die "Template failed: ", $template->error(), "\n";
}

sub main {
    print $q->header, $q->start_html( -title => "Online Payments" );

    if ( $q->param('x_response_code') ) {
        $pay = &parse_anet_relay;

        #print $q->pre(Dumper($pay));

        # verify message is valid and successful
        if ( $pay->{"is_valid"} && $pay->{"is_success"} ) {
   #        print $q->p("Thank you for your payment! Your account will reflect the new payment soon.");
	    show_receipt();
            #print $q->pre(JSON::XS->new->pretty->ascii->encode($pay));
            my $filename = save_queue_file($pay)
          	|| die "Writing queue file failed";

        	if ($filename){
                	sleep 3;
                	system "/openils/var/web/pay/post-credit.pl -f $filename"
			   || die "Posting payment failed.";
        	}

        } else {
            print $q->p("There was a problem accepting your payment. ");
            if (!$pay->{"is_success"}) {
                print $q->p("Your card was NOT charged.");
            }
            print $q->p("Please contact the library at 616-988-5400 for assistance.");
        }
        
 
    } else {
        print $q->p("nothing received.");
    }

    print $q->end_html;
}

&main();
