#! env perl

use strict;
use feature qw/say/;
use LWP;
use Data::Dumper;


my $username = 'test';
my $password = 'test';

my $ua = LWP::UserAgent->new;
$ua->cookie_jar({});

my $login_req = LWP::Request->new(POST => 'https://workflowy.com/accounts/login');
$login_req->content_type('application/x-www-form-urlencoded');
$login_req->content("username=$username&password=$password");


