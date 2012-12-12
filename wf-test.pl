#! env perl

use strict;
use feature qw/say/;
use LWP;
use Data::Dumper;


my $username = 'test';
my $password = 'test';

my $ua = LWP::UserAgent->new;
$ua->cookie_jar({});

unless (log_in($ua, $username, $password)) {
  die "couldn't log in.  sad face.";
}


#my $req = HTTP::Request->new(GET => 'https://workflowy.com/');
#my $resp = $ua->request($req);
#say Dumper($resp);

my $req = HTTP::Request->new(GET => 'https://workflowy.com/get_project_tree_data');
my $resp = $ua->request($req);
say Dumper($resp);

# 
  


=item log_in($ua, $username, $password)

Log in to a Workflowy account.

=cut

sub log_in {
  
  # will return 200 on failed login, 302 on success
  my $req = HTTP::Request->new(POST => 'https://workflowy.com/accounts/login/');
  $req->content_type('application/x-www-form-urlencoded');
  $req->content("username=$username&password=$password");
  my $resp = $ua->request($req);
  
  if ($resp->code == 200) {
    say "failed to log in";
    return 0;
  }

  if ($resp->code == 302) {
    say "login successful";
    return 1;
  }

  say "not sure what happened";
  say Dumper($resp);
}

