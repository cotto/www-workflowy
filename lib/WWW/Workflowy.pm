package WWW::Workflowy;

use Moose;

use HTTP::Request;
use LWP::UserAgent;
use Date::Parse;
use POSIX;

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
  'isa' => 'HashRef',
  'default' => sub { {} },
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

=item get_tree($ua)

Retrieve the current state of this user's Workflowy tree.

=cut

sub get_tree {
  my ($self) = @_;

  my $req = HTTP::Request->new(GET => 'https://workflowy.com/get_project_tree_data');
  my $resp = $self->ua->request($req);
  unless ($resp->is_success) {
    return 0;
  }

  my $contents = $resp->decoded_content;
  my $json = JSON->new->allow_nonref;

  # do some ghetto js parsing
  # lucky for us, all the important variables are on a single line

  foreach my $line (split /\n/, $contents) {
    next unless $line =~ m/^var/ && $line =~ m/;$/;
    $line =~ m/^var (?<var_name>[A-Z_]+) = (?<var_json>.*);$/;
    $self->tree->{ lc $+{var_name} } = $json->decode( $+{var_json} );
    #say "assigned $+{var_name} the value $+{var_json}";
  }
  $self->tree->{start_time_in_ms} = floor( 1000 * str2time($self->tree->{client_id}) );
  $self->_build_parent_map();
}


=item _build_parent_map()

Calculate and cache information on each item's parents.

=cut

sub _build_parent_map {
  my ($self) = @_;

  $self->tree->{parent_map} = {};
  #say Dumper($self->tree);

  foreach my $child (@{$self->tree->{main_project_tree_info}{rootProjectChildren}}) {
    my $current_parent = 'root';
    #say Dumper($child);
    $self->tree->{parent_map}{ $child->{id} } = $current_parent;
    if (exists $child->{ch}) {
      $self->_build_parent_map_rec($child->{id}, $child->{ch});
    }
  }
  #say Dumper($self->tree->{parent_map});
}


=item _build_parent_map_rec($children, $parent_id)

Helper for _build_parent_map.

=cut

sub _build_parent_map_rec {
  my ($self, $parent_id, $children) = @_;

  foreach my $child (@$children) {
    $self->tree->{parent_map}{ $child->{id} } = $parent_id;
    if (exists $child->{ch}) {
      $self->_build_parent_map_rec($child->{id}, $child->{ch});
    }
  }
}






1;
