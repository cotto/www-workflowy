package WWW::Workflowy;

# ABSTRACT: an unofficial API for Workflowy
use strict;
use warnings;
use Moose;
use MooseX::Storage;

use HTTP::Request;
use LWP::UserAgent;
use Date::Parse;
use POSIX;
use JSON;

with Storage('format' => 'YAML', 'io' => 'File');


=head1 SYNOPSIS

  use WWW::Workflowy;

  # manually log in and update the tree
  my $wfl = WWW::Workflowy->new();
  $wfl->log_in('workflowy_user@example.com', 'workflowy_password');
  $wfl->get_tree();

  # same as above but with less code
  my $wfl = WWW::Workflowy->new( username => 'workflowy_user@example.com', password => 'workflowy_password');

  # all list data lives in $wfl->tree
  use Data::Dumper;
  print Dumper($wfl->tree);

  # create a new item
  my $parent_id = ...; # grab the id of a parent from $wfl->tree
  my $child_data = {
    name => 'This is a new Workflowy list item!',
    note => 'This item has a note', # optional
    priority => 999, # put this item below all its siblings
  };
  $wfl->create_item( $parent_id, $child_data);

  # update an item
  my $item_data = {
    id => ..., # grab this value from $wfl->tree
    name => "This item has been edited."
    note => "This note has been edited too.",
  }
  $wfl->update_item($item_data);


  # log out (happens automatically during object destruction)
  $wfl->log_out();

=head1 DESCRIPTION

  This module provides an unoffical Perl interface for retrieving and manipulating the data stored in a Workflowy list.

  Note that Workflowy do not currently attempt to maintain a stable API, so it is possible that this module could break without notice.  The maintainer of this module uses it on a daily basis and will try to keep it running, but using it for anything mission-critical is ill-advised.

  This module is not officially affiliated with or supported by Workflowy.

=cut


=attr ua

the user agent used to access Workflowy

=cut

has 'ua' => (
  is => 'ro',
  isa => 'LWP::UserAgent',
  lazy => 1,
  default => sub {
    LWP::UserAgent->new(
      cookie_jar => {},
      agent      => 'WWW::Workflowy',
    );
  },
  metaclass => 'DoNotSerialize',
);

=attr tree

This is a read-only ArrayRef that contains all items in the workflowy list.  To modify the tree, use edit_item or create_item.  Each item has the following format:

=over 4

=item * id - a UUID that identifies this item

=item * nm - the name of this item

=item * no - the note attached to this item (only present when used)

=item * ch - an ArrayRef of this item's children (only present when used)

=back

=cut

has 'tree' => (
  is => 'rw',
  isa => 'ArrayRef',
  default => sub { [] },
);

=attr config

stores configuration information from Workflowy

=cut

has 'config' => (
  is => 'ro',
  isa => 'HashRef',
  default => sub { {} },
);

=attr last_transaction_id

stores the id of the most recent transaction

=cut

has 'last_transaction_id' => (
  is => 'rw',
  isa => 'Int',
);

=attr logged_in

true if this instance has successfully logged in and hasn't logged out yet

=cut

has 'logged_in' => (
  is        => 'rw',
  isa       => 'Bool',
  default   => sub { 0 },
  # when an object gets serialized, assume that the session and ua were destroyed
  metaclass => 'DoNotSerialize',
);

=attr parent_map

internal cache that maps child ids to parent ids

=cut

has 'parent_map' => (
  is => 'rw',
  isa => 'HashRef',
  default => sub { {} },
);

=attr id_map

internal cache that maps ids to item hashrefs

=cut

has 'id_map' => (
  is => 'rw',
  isa => 'HashRef',
  default => sub { {} },
);

=attr wf_uri

the url where Workflowy (or some hypothetical compatible service) lives

=cut

has 'wf_uri' => (
  is => 'ro',
  isa => 'Str',
  default => sub { 'https://workflowy.com' },
);


=attr client_version

workflowy-internal int that's used for API versioning; if this changes, API breakage is very likely

=cut

has 'client_version' => (
  is => 'ro',
  isa => 'Int',
  init_arg => undef,
  default => sub { 9 },
);


sub BUILD {
  my ($self, $args) = @_;

  if (exists $args->{username} && exists $args->{password}) {
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

=method log_in($username, $password)

Log in to a Workflowy account.

=cut

sub log_in {

  my ($self, $username, $password) = @_;

  # Workflowy will return 200 on failed login and 302 on success.  This would
  # be more of a wtf if the API were designed for external users, but its only
  # intended use is via the web frontend, so it is what it is.
  my $req = HTTP::Request->new(POST => $self->wf_uri.'/accounts/login/');
  $req->content_type('application/x-www-form-urlencoded');
  $req->content("username=$username&password=$password");
  my $resp = $self->ua->request($req);

  # 200 means that the login definitely failed.
  if ($resp->code == 200) {
    die __PACKAGE__.": login attempt failed for user '$username'";
  }

  # 302 means that the login definitely succeeded.
  if ($resp->code == 302) {
    $self->logged_in(1);
    return;
  }

  # Anything else probably means that the login failed.
  die __PACKAGE__.": login attempt failed for user '$username'";
}



=method log_out($ua)

Be polite and log out.  This method is called automatically on destruction, so you probably don't need to use it explicitly unless you're doing something unusual.

=cut

sub log_out {
  my ($self) = @_;

  my $req = HTTP::Request->new(GET => $self->wf_uri.'/offline_logout?so_long_and_thanks_for_all_the_fish');
  $self->ua->request($req);
  $self->logged_in(0);
}


=method get_tree($ua)

Retrieve the current state of this user's Workflowy tree.  Since this is the
primary method of retrieving data from Workflowy, you'll need to call this
method before attempting to manipulate any Workflowy data.

=cut

sub get_tree {
  my ($self) = @_;

  die __PACKAGE__." must be logged in before calling get_tree" unless $self->logged_in;

  my $req = HTTP::Request->new(GET => $self->wf_uri.'/get_project_tree_data');
  my $resp = $self->ua->request($req);
  unless ($resp->is_success) {
    die __PACKAGE__." couldn't retrieve tree: ".$resp->status_line;
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
        $self->config->{$key} = $self->_unboolify($var_contents->{$key});
      }
    }
    else {
      $self->config->{ lc $+{var_name} } = $self->_unboolify($var_contents);
    }
  }
  $self->config->{start_time_in_ms} = floor( 1000 * str2time($self->config->{client_id}) );
  $self->_update_maps();
}

=method _unboolify($thing)

If $thing is a JSON bool, return 0 or 1 appropriate so that serialization doesn't break.  Otherwise return the thing.

=cut

sub _unboolify {

  my ($self, $thing) = @_;
  if (JSON::is_bool($thing)) {
    return $thing ? 1 : 0;
  }
  return $thing;
}


=method update_item($item_data)

Modify the name and/or notes of an existing item.

=cut

sub update_item {
  my ($self, $item_data) = @_;

  die __PACKAGE__." must be logged in before editing an item" unless $self->logged_in;

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
    "client_version=".$self->client_version(),
    "push_poll_id=".$self->_gen_push_poll_id(8),
    "push_poll_data=$push_poll_json");

  $req->content($req_data);
  my $resp = $self->ua->request($req);

  unless ($resp->is_success) {
    die __PACKAGE__." couldn't update item: ".$resp->status_line;
  }

  my $resp_obj = decode_json($resp->decoded_content);
  $self->_run_wf_ops($resp_obj);
}


=method create_item($parent_id, $child_data)

Create a child item below the specified parent and return the id of the new child.

=cut

sub create_item {
  my ($self, $parent_id, $child_data) = @_;

  die __PACKAGE__." must be logged in before calling create_item" unless $self->logged_in;

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
    "client_version=".$self->client_version(),
    "push_poll_id=".$self->_gen_push_poll_id(8),
    "push_poll_data=$push_poll_json");

  $req->content($req_data);
  my $resp = $self->ua->request($req);
  unless ($resp->is_success) {
    die __PACKAGE__." couldn't create new item: ".$resp->status_line;
  }

  my $resp_obj = decode_json($resp->decoded_content);
  $self->_run_wf_ops($resp_obj);

  return $child_id;
}


=method _last_transaction_id

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
    "client_version=".$self->client_version(),
    "push_poll_id=".$self->_gen_push_poll_id(8),
    "push_poll_data=$push_poll_json");

  $req->content($req_data);
  my $resp = $self->ua->request($req);
  unless ($resp->is_success) {
    die __PACKAGE__." couldn't get most recent transaction id: ".$resp->status_line;
  }
  my $wf_json = $resp->decoded_content();
  $self->last_transaction_id(decode_json($wf_json)->{results}[0]{new_most_recent_operation_transaction_id});
  return $self->last_transaction_id;
}

=method _client_timestamp($wf_tree)

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

=method _run_wf_ops ()

apply a set of operations from Workflowy to the local representation of the tree

=cut

sub _run_wf_ops {

  my ($self, $commands) = @_;

  if ($commands->{results}[0]{error_encountered_in_remote_operations}) {
    die __PACKAGE__." Something broke when Workflowy tried to run that command.";
  }

  my $server_ops = decode_json($commands->{results}[0]{server_run_operation_transaction_json});

  my %op_table = (
    edit   => \&_apply_edit_op,
    create => \&_apply_create_op,
    move   => \&_apply_move_op,
    delete => \&_apply_delete_op,
    # nyi commands:
    # complete
    # uncomplete
    # bulk_create
    # undelete
    # share
    # unshare
    # add_shared_email
    # remove_shared_email
    # register_shared_email_user
    # make_shared_subtree_placeholder
    # bulk_create
  );

  foreach my $op (@{$server_ops->{ops}}) {
    my $op_type = $op->{type};
    my $op_data = $op->{data};
    unless (defined $op_table{$op_type}) {
      die __PACKAGE__." unknown op type '$op_type'";
    }
    $self->($op_table{$op_type})($op_data);
    use Data::Dumper;
    print "OP RUNNING TIEM: op is '$op_type'";
    print "data is ".Dumper($op_data);


    # operations
    #
  }
}

=method _apply_create_op($op_data)

Apply a create operation from Workflowy to the local tree.

=cut

sub _apply_create_op {
  my ($self, $op_data) = @_;
  # * create
  #   projectid
  #   priority
  #   parentid
}

=method _apply_edit_op($op_data)

Apply an edit operation from Workflowy to the local tree.

=cut

sub _apply_edit_op {
  my ($self, $op_data) = @_;
  # * edit
  #   projectid
  #   name (note: responses tend to have either a name xor a description)
  #   description
}

=method _apply_move_op($op_data)

Apply a move operation from Workflowy to the local tree.

=cut

sub _apply_move_op {
  my ($self, $op_data) = @_;
  # * move
  #   projectid
  #   parentid
  #   priority
}

=method _apply_delete_op($op_data)

Apply a delete operation from Workflowy to the local tree.

=cut

sub _apply_delete_op {
  my ($self, $op_data) = @_;
  # * delete (note that recursive deletion is implicit)
  #   projectid
}

=method _gen_push_poll_id($len)

Generate a random alnum string of $len characters.

=cut

sub _gen_push_poll_id{
  my ($self, $len) = @_;
  join "", map {('0'..'9','A'..'Z','a'..'z')[rand 62]} 1..$len;
}

=method _gen_uuid

Generate a uuid using rand as the source of entropy.

=cut

sub _gen_uuid {
  # 12345678-1234-1234-1234-123456789012
  # 8922a424-1e51-629c-efee-9e7facb70cce
  join '-', map { join "", map {('0'..'9','a'..'f')[rand 16]} 1..$_ } qw/8 4 4 4 12/;
}




=method _update_maps

Calculate and cache information on each item.

=cut

sub _update_maps {
  my ($self) = @_;

  $self->parent_map( {} );
  $self->id_map( {} );

  foreach my $child (@{$self->tree}) {
    my $current_parent = 'root';
    $self->parent_map->{ $child->{id} } = $current_parent;
    $self->id_map->{ $child->{id} } = \$child;
    if (exists $child->{ch}) {
      $self->_update_maps_rec($child->{id}, $child->{ch});
    }
  }
}

=method _update_maps_rec($children, $parent_id)

helper for _update_maps

=cut

sub _update_maps_rec {
  my ($self, $parent_id, $children) = @_;

  foreach my $child (@$children) {
    $self->parent_map->{ $child->{id} } = $parent_id;
    $self->id_map->{ $child->{id} } = \$child;
    if (exists $child->{ch}) {
      $self->_update_maps_rec($child->{id}, $child->{ch});
    }
  }
}

=method _check_client_version

Try to check that Workflowy isn't serving an unknown version of their api.  If the version number from Workflowy is different from the hard-coded value from this module, return false.  Otherwise return true;

=cut

sub _check_client_version {
  my ($self) = @_;

  # Grab Workflowy's source.js file and use it to figure out what the current
  # client version number is.
  my $req = HTTP::Request->new( GET => $self->wf_uri."/media/js/source.js" );
  my $resp = $self->ua->request($req);

  unless ($resp->is_success) {
    die __PACKAGE__." couldn't retrieve source.js: ".$resp->status_line;
  }

  # more ghetto js parsing
  $resp->decoded_content =~ /CLIENT_VERSION=(?<client_version>\d+),/;
  my $client_version = $+{client_version};

  return !!($client_version == $self->client_version());
}




__PACKAGE__->meta->make_immutable;

1;
