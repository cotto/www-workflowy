#!/usr/bin/perl

use strict;
use warnings;
use LWP::Online ':skip_all';
use Test::More tests => 11;
use Test::Exception;
use WWW::Workflowy;

# Perform tests that don't modify any Workflowy data and therefore won't impact
# usage quotas for non-pro users.

my $wf_user = $ENV{WORKFLOWY_USERNAME} // 'test';
my $wf_password = $ENV{WORKFLOWY_PASSWORD} // 'test';

my $wfl = WWW::Workflowy->new();

is( $wfl->logged_in, 0, "before login, ->logged_in returns faslse" );

dies_ok { $wfl->log_in('NOT_A_REAL_USER', 'NOT_A_REAL_PASSWORD_EITHER') } "invalid login attempt failed";

lives_ok { $wfl->log_in($wf_user, $wf_password); } "correct login with $wf_user succeeded";

is( $wfl->logged_in, 1, "after login, ->logged_in returns true" );

lives_ok { $wfl->get_tree } "was able to grab tree from Workflowy";

isnt(@{$wfl->tree}, 0, "tree from Workflowy isn't empty");

lives_ok { $wfl->log_out } "logging out didn't explode";

is( $wfl->logged_in, 0, "logging out seems to have been effective");


lives_ok { $wfl = WWW::Workflowy->new( username => $wf_user, password => $wf_password ) } "fancy initialization didn't explode";
is( $wfl->logged_in, 1, "fancy init logged in automatically" );
isnt( @{$wfl->tree}, 0, "fancy init called get_tree" );

