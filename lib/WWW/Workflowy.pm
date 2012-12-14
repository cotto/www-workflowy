package WWW::Workflowy;

use Moose;

use HTTP::Request;
use LWP::UserAgent;

has 'ua' => (
  'is' => 'ro',
  # make this private
  'init_arg' => undef,
  'isa' => 'LWP::UserAgent',
  'default' => sub {
    LWP::UserAgent->new(
      cookie_jar => {},
      agent      => 'WWW::Workflowy',
    );
  },
);

has 'tree' => (
  'is' => 'ro',
);


=item log_in($username, $password)

Log in to a Workflowy account.

=cut

sub log_in {

  my ($self, $username, $password) = @_;

  # will return 200 on failed login, 302 on success
  my $req = HTTP::Request->new(POST => 'https://workflowy.com/accounts/login/');
  $req->content_type('application/x-www-form-urlencoded');
  $req->content("username=$username&password=$password");
  my $resp = $self->ua->request($req);

  if ($resp->code == 200) {
    #say "failed to log in";
    return 0;
  }

  if ($resp->code == 302) {
    #say "login successful";
    return 1;
  }

  #say "not sure what happened";
  #say Dumper($resp);
}



1;
