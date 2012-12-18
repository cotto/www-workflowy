package WWW::Workflowy;

use Moose;

use HTTP::Request;
use LWP::UserAgent;
use Date::Parse;
use POSIX;
use JSON;

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
  'is' => 'rw',
  'isa' => 'ArrayRef',
  'default' => sub { [] },
);

has 'config' => (
  'is' => 'ro',
  'isa' => 'HashRef',
  'default' => sub { {} },
);

has 'last_transaction_id' => (
  'is' => 'rw',
  'isa' => 'Int',
); 

has 'logged_in' => (
  'is'        => 'rw',
  'isa'       => 'Bool',
  'clearer'   => 'clear_logged_in',
  'predicate' => 'is_logged_in',
);

has 'parent_map' => (
  'is' => 'rw',
  'isa' => 'HashRef',
  'default' => sub { {} },
);

has 'wf_uri' => (
  'is' => 'ro',
  'isa' => 'Str',
  'default' => sub { 'https://workflowy.com' },
);

# TODO:
# * throw exceptions on errors
# * look for some moose magic to deal with BUILD args
# * check out a few other Moose API modules to see if I'm missing anything
#   important
# * tests (basic, ro and full
#   * need to be cognizant of the fact that item creation is rate-limited for
#     non-paying users
#   * paying users get 1M items/month, so that's a thing
# * proper readme, documentation and examples
# * move wf-test.pl into a separate repo
# * think about a persistence layer that syncs w/ wf on init rather than
#   grabbing the entire tree
# * check the client version, make sure that if it changes, there's a very
#   good chance that something will break
# * do something better than ghetto parsing of js, or at least make it less
#   ghetto
# * make the client_timestamp calculation less horribly wrong


sub BUILD {
  my ($self, $args) = @_;

  if (%$args) {
    $self->log_in($args->{username}, $args->{password});
    $self->get_tree();
  }
}

sub DEMOLISH {
  my ($self) = @_;
  if ($self->logged_in) {
    $self->log_out();
    $self->logged_in(0);
  }
}

=item log_in($username, $password)

Log in to a Workflowy account.

=cut

sub log_in {

  my ($self, $username, $password) = @_;

  # will return 200 on failed login, 302 on success
  my $req = HTTP::Request->new(POST => $self->wf_uri.'/accounts/login/');
  $req->content_type('application/x-www-form-urlencoded');
  $req->content("username=$username&password=$password");
  my $resp = $self->ua->request($req);

  if ($resp->code == 200) {
    return 0;
  }

  if ($resp->code == 302) {
    $self->logged_in(1);
    return 1;
  }

  return 0;
}



=item log_out($ua)

Be polite and log out.  This method is called automatically on destruction.

=cut

sub log_out {
  my ($self) = @_;

  my $req = HTTP::Request->new(GET => $self->wf_uri.'/offline_logout?so_long_and_thanks_for_all_the_fish');
  $self->ua->request($req);
  $self->clear_logged_in;
}


=item get_tree($ua)

Retrieve the current state of this user's Workflowy tree.

=cut

sub get_tree {
  my ($self) = @_;

  die "must be logged in before calling get_tree" unless $self->is_logged_in;

  my $req = HTTP::Request->new(GET => $self->wf_uri.'/get_project_tree_data');
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
    my $lc_name = lc $+{var_name};
    my $var_contents = $json->decode($+{var_json});

    # consolidate all config info into $self->config and put the list structure
    # in $self->tree
    if ($lc_name eq 'main_project_tree_info') {
      $self->tree($var_contents->{rootProjectChildren}); 
      delete $var_contents->{rootProjectChildren};
      foreach my $key (keys $var_contents) {
        $self->config->{$key} = $var_contents->{$key};
      }
    }
    else {
      $self->config->{ lc $+{var_name} } = $var_contents;
    }
  }
  $self->config->{start_time_in_ms} = floor( 1000 * str2time($self->config->{client_id}) );
  $self->_build_parent_map();
}


=item edit_item($item_data) 

Modify the name and/or notes of an existing item.

=cut

sub edit_item {
  my ($self, $item_data) = @_;
  
  die "must be logged in before editing an item" unless $self->is_logged_in;

  my $req = HTTP::Request->new(POST => $self->wf_uri.'/push_and_poll');
  $req->content_type('application/x-www-form-urlencoded');
  my $client_id = $self->config->{client_id};


  # build the push/poll data
  my $push_poll_data = [
    { 
      most_recent_operation_transaction_id => $self->_last_transaction_id(),
      operations => [
        { 
          type => 'edit',
          data => {
            projectid => $item_data->{id},
            name => $item_data->{name},
            description => $item_data->{note} // '',
          },

          # The wf web client sends this, but it doesn't appear to be strictly necessary.
          #undo_data => {
          #  previous_last_modified => '????',
          #  previous_name => '????',
          #},

          client_timestamp => $self->_client_timestamp(),
        },
      ],
    },
  ];

  my $push_poll_json = encode_json($push_poll_data);

  my $req_data = join('&',
    "client_id=$client_id".
    "client_version=9",
    "push_poll_id=".$self->_gen_push_poll_id(8),
    "push_poll_data=$push_poll_json");

  $req->content($req_data);
  $self->ua->request($req);
}


=item create_item($parent_id, $child_data) 

Create a child item below the specified parent and return the id of the new child.

=cut

sub create_item {
  my ($self, $parent_id, $child_data) = @_;

  die "must be logged in before calling create_item" unless $self->is_logged_in;

  my $req = HTTP::Request->new(POST => $self->wf_uri.'/push_and_poll');
  $req->content_type('application/x-www-form-urlencoded');
  my $client_id = $self->config->{client_id};
  my $child_id = $self->_gen_uuid();

  # build the push/poll data
  my $push_poll_data = [
    { 
      most_recent_operation_transaction_id => $self->_last_transaction_id(),
      operations => [
        { 
          type => 'create',
          data => {
             projectid => $child_id,
             parentid => $parent_id,
             # priority determines the order in which this item is listed among its siblings
             priority => $child_data->{priority} // 999,
          },
          undo_data => {},
          client_timestamp => $self->_client_timestamp(),
        },
        {
          type => "edit",
          data => {
            projectid => $child_id,
            name => $child_data->{name},
            description => $child_data->{note} // '',
          },
          undo_data => {
            previous_last_modified => 293140,
            previous_name => "",
          },
          client_timestamp => $self->_client_timestamp(),
        },
      ],
    },
  ];

  my $push_poll_json = encode_json($push_poll_data);

  my $req_data = join('&',
    "client_id=$client_id".
    "client_version=9",
    "push_poll_id=".$self->_gen_push_poll_id(8),
    "push_poll_data=$push_poll_json");

  $req->content($req_data);
  my $resp = $self->ua->request($req);
  return $child_id;
}



=item find_parent_id($child_id)

Given the id of a valid child, return the id of its immediate parent.

=cut

sub find_parent_id {
  my ($self, $child_id) = @_;

  return $self->parent_map->{ $child_id };
}



=item _last_transaction_id() 

Return the id of the most recent transaction.

=cut

sub _last_transaction_id {

  my ($self) = @_;

  # TODO: this data is already in the tree under initialMostRecentOperationTransactionId
  # TODO: invalidate/update this when an update is made
  
  my $req = HTTP::Request->new(POST => $self->wf_uri.'/push_and_poll');
  $req->content_type('application/x-www-form-urlencoded');
  my $client_id = $self->config->{client_id};

  my $push_poll_data = [
    {
      # Using a low value for this will cause workflowy to return all
      # transactions since that one, so that's bad.  Using an invalid number
      # causes an internal error in wf.  Using a number that's way too high
      # will cause wf to send back the current
      # new_most_recent_operation_transaction_id and no extra junk.
      most_recent_operation_transaction_id => "999999999",
    },
  ];

  my $push_poll_json = encode_json($push_poll_data);

  my $req_data = join('&',
    "client_id=$client_id".
    "client_version=9",
    "push_poll_id=".$self->_gen_push_poll_id(8),
    "push_poll_data=$push_poll_json");

  $req->content($req_data);
  my $resp = $self->ua->request($req);
  my $wf_json = $resp->decoded_content();
  $self->last_transaction_id(decode_json($wf_json)->{results}[0]{new_most_recent_operation_transaction_id});
  return $self->last_transaction_id;
}




=item _client_timestamp($wf_tree)

Calculate and return the client_timestamp, as expected by workflowy.  Omitting
this field from a request appears to have no effect, but I implemented it while
debugging something else and don't see any reason not to keep the code around.

=cut

sub _client_timestamp {
  my ($self) = @_;

  # client_timestamp is the number of minutes since the current account first
  # registered with workflowy plus the number of minutes since this client
  # first connected.  Since this client does all its work less than a minute after
  # connecting, the second part of the calculation will always be zero.
  my $mins_since_joined = $self->config->{minutesSinceDateJoined};

  # The rest of these values will be needed if this client ever connects for
  # more than one minute and wants to continue to return valid timestamps.
  #my $curr_time_in_ms = floor( 1000 * DateTime->now()->epoch() );
  #my $start_time_in_ms = $wf_tree->{start_time_in_ms};
  #my $client_timestamp = $mins_since_joined + floor(($curr_time_in_ms - $start_time_in_ms) / 60_000);
  return $mins_since_joined;
}
      



=item _gen_push_poll_id($len)

Generate a random alnum string of $len characters.

=cut

sub _gen_push_poll_id{
  my ($self, $len) = @_;
  join "", map {('0'..'9','A'..'Z','a'..'z')[rand 62]} 1..$len;
}

=item _gen_uuid()

Generate a uuid using rand as the source of entropy.

=cut

sub _gen_uuid {
  # 12345678-1234-1234-1234-123456789012
  # 8922a424-1e51-629c-efee-9e7facb70cce
  join '-', map { join "", map {('0'..'9','a'..'f')[rand 16]} 1..$_ } qw/8 4 4 4 12/;
}
  
            


=item _build_parent_map()

Calculate and cache information on each item's parents.

=cut

sub _build_parent_map {
  my ($self) = @_;

  foreach my $child (@{$self->tree}) {
    my $current_parent = 'root';
    $self->parent_map->{ $child->{id} } = $current_parent;
    if (exists $child->{ch}) {
      $self->_build_parent_map_rec($child->{id}, $child->{ch});
    }
  }
}


=item _build_parent_map_rec($children, $parent_id)

Helper for _build_parent_map.

=cut

sub _build_parent_map_rec {
  my ($self, $parent_id, $children) = @_;

  foreach my $child (@$children) {
    $self->parent_map->{ $child->{id} } = $parent_id;
    if (exists $child->{ch}) {
      $self->_build_parent_map_rec($child->{id}, $child->{ch});
    }
  }
}




__PACKAGE__->meta->make_immutable;

1;
