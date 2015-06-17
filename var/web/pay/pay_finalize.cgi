#!/usr/bin/perl

use CGI qw(:standard);
use Config::Tiny;
use Data::Dumper;
use POSIX qw(strftime);
use Digest::HMAC_MD5 qw(hmac_md5 hmac_md5_hex);

print header;

my $Config = Config::Tiny->read( '/openils/conf/grpl/pay.ini' );
my $anet_login = $Config->{"authorize.net"}->{"login"};
my $anet_key = $Config->{"authorize.net"}->{"key"};


my $amount=param('x_amount');
my $sequence = param('x_fp_sequence');
my $timestamp = param('x_fp_timestamp');
my $fingerprint = hmac_md5_hex($anet_login . "^" . $sequence . "^" . $timestamp . "^" . $amount . "^", $anet_key);

print $fingerprint;


