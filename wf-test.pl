#! env perl

use strict;
use feature qw/say state/;
use LWP;
use Data::Dumper;
use JSON;
use Data::DPath qw/dpath/;
use URL::Encode qw/url_encode/;
use DateTime;
use Date::Parse;
use POSIX;


my $username = 'test';
my $password = 'test';

my $ua = LWP::UserAgent->new;
$ua->cookie_jar({});

unless (log_in($ua, $username, $password)) {
  die "couldn't log in.  sad face.";
}

say "grabbing tree";
my $wf_tree = get_wf_tree($ua);

say "editing item";
#edit_item($ua, {
#    id => '5a4d3097-72d0-9029-ee63-7653c0624343',
#    name => "I've got a lovely bunch of coconuts.",
#  }, $wf_tree,
#);
say "trying to create a child";
create_item($ua, '3fa535e1-06b3-4406-0e75-4ddba7c9d606', {name => "child creation test number the fourth", priority => 2}, $wf_tree);

say "loggging out";
log_out($ua); exit;




#my $children = $wf_tree ~~ dpath '//rootProjectChildren//nm[ value =~ /#food-log/ ]/..';
#my $date_weights = [];
#
#foreach my $child (@$children) {
#  my $date = $child->{nm};
#  $date =~ s/#food-log //;
#  my $weights = $child ~~ dpath '//nm[ value =~ /^weight/ ]';
#  my $weight = $weights->[0];
#  $weight =~ s/[^0-9.]//g;
#  say "on $date, weight was $weight";
#}

# GOAL:
# * grab the weight info from all #food-log entries
# * mangle it into a nice list
# * for each day
#   * create a stats item if needed
#   * calculate the 10-day exponentially smoothed average (and whatever else seems expedient)
#   * get the uuid of the stats item
#   * update the contents of the stats item


log_out($ua);


  
=item rand_string($len)

Generate a random alnum string of $len characters.

=cut

sub rand_string {
  my $len = shift;
  my $s = join "", map ('0'..'9','A'..'Z','a'..'z')[rand 62], 1..$len;
  return $s
}


=item _gen_uuid()

Generate a uuid using rand as the source of entropy.

=cut

sub _gen_uuid {
  # 12345678-1234-1234-1234-123456789012
  # 8922a424-1e51-629c-efee-9e7facb70cce
  join '-', map { join "", map {('0'..'9','a'..'f')[rand 16]} 1..$_ } qw/8 4 4 4 12/;
}


=item log_in($ua, $username, $password)

Log in to a Workflowy account.

=cut

sub log_in {

  my ($ua, $username, $password) = @_;
  
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


=item log_out($ua)

Be polite and log out.

=cut

sub log_out {
  my ($ua) = @_;

  my $req = HTTP::Request->new(GET => 'https://workflowy.com/offline_logout?so_long_and_thanks_for_all_the_fish');
  my $resp = $ua->request($req);
}


=item get_wf_tree($ua)

Return a hashref containing all of the Workflowy tree for the current logged-in
user, or 0 on failure.

=cut

sub get_wf_tree {
  my ($ua) = @_;

  my $req = HTTP::Request->new(GET => 'https://workflowy.com/get_project_tree_data');
  my $resp = $ua->request($req);
  unless ($resp->is_success) {
    return 0;
  }

  my $contents = $resp->decoded_content;
  my $json = JSON->new->allow_nonref;

  # do some ghetto js parsing
  # lucky for us, all the important variables are on a single line

  my $wf_tree = {};
  foreach my $line (split /\n/, $contents) {
    next unless $line =~ m/^var/ && $line =~ m/;$/;
    $line =~ m/^var (?<var_name>[A-Z_]+) = (?<var_json>.*);$/;
    $wf_tree->{ lc $+{var_name} } = $json->decode( $+{var_json} );
    #say "assigned $+{var_name} the value $+{var_json}";
  }
  $wf_tree->{start_time_in_ms} = floor( 1000 * str2time($wf_tree->{client_id}) );
  return $wf_tree;
}


=item edit_item($ua, $item_data, $wf_tree) 

Modify the name and/or notes of an existing item.

=cut

sub edit_item {
  my ($ua, $item_data, $wf_tree) = @_;

  my $req = HTTP::Request->new(POST => 'https://workflowy.com/push_and_poll');
  $req->content_type('application/x-www-form-urlencoded');
  my $client_id = $wf_tree->{client_id};


  # build the push/poll data
  my $push_poll_data = [
    {
      most_recent_operation_transaction_id => _last_transaction_id($ua, $wf_tree),
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
          
          # This also appears to be optional.
          client_timestamp => _client_timestamp($wf_tree),
        },
      ],
    },
  ];

  my $push_poll_json = encode_json($push_poll_data);

  my $req_data = join('&',
    "client_id=$client_id".
    "client_version=9",
    "push_poll_id=".rand_string(8),
    "push_poll_data=$push_poll_json");
  
  $req->content($req_data);
  my $resp = $ua->request($req);

}

=item create_item($ua, $parent_id, $child_data, $wf_tree) 

Create a child item below the specified parent.

=cut

sub create_item {
  my ($ua, $parent_id, $child_data, $wf_tree) = @_;

  my $req = HTTP::Request->new(POST => 'https://workflowy.com/push_and_poll');
  $req->content_type('application/x-www-form-urlencoded');
  my $client_id = $wf_tree->{client_id};
  my $child_id = _gen_uuid();

  # build the push/poll data
  my $push_poll_data = [
    {
      most_recent_operation_transaction_id => _last_transaction_id($ua, $wf_tree),
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
          client_timestamp => _client_timestamp($wf_tree),
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
          client_timestamp => _client_timestamp($wf_tree),
        },
      ],
    },
  ];

  my $push_poll_json = encode_json($push_poll_data);

  my $req_data = join('&',
    "client_id=$client_id".
    "client_version=9",
    "push_poll_id=".rand_string(8),
    "push_poll_data=$push_poll_json");
  
  $req->content($req_data);
  my $resp = $ua->request($req);
  say Dumper($resp);

}


=item _client_timestamp($wf_tree)

Calculate and return the client_timestamp, as expected by workflowy.

=cut

sub _client_timestamp {
  my ($wf_tree) = @_;

  # client_timestamp is the number of minutes since the current account first
  # registered with workflowy plus the number of minutes since this client
  # first connected.  Since this client does all its work less than a minute after
  # connecting, the second part of the calculation will always be zero.
  my $mins_since_joined = $wf_tree->{main_project_tree_info}{minutesSinceDateJoined};
  my $curr_time_in_ms = floor( 1000 * DateTime->now()->epoch() );
  my $start_time_in_ms = $wf_tree->{start_time_in_ms};
  my $client_timestamp = $mins_since_joined + floor(($curr_time_in_ms - $start_time_in_ms) / 60_000);
  return $mins_since_joined;
}


=item _last_transaction_id($ua, $wf_tree) 

Grab the id of the most recent transaction.

=cut

sub _last_transaction_id {

  my ($ua, $wf_tree) = @_;

  # TODO: this data is already in wf_tree under initialMostRecentOperationTransactionId

  # TODO: invalidate/update this when an update is made
  state $transaction_id = "";

  if ($transaction_id ne "") {
    return $transaction_id;
  }
  
  my $req = HTTP::Request->new(POST => 'https://workflowy.com/push_and_poll');
  $req->content_type('application/x-www-form-urlencoded');
  my $client_id = $wf_tree->{client_id};

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
    "push_poll_id=".rand_string(8),
    "push_poll_data=$push_poll_json");
  
  $req->content($req_data);
  my $resp = $ua->request($req);
  my $wf_json = $resp->decoded_content();
  $transaction_id = decode_json($wf_json)->{results}[0]{new_most_recent_operation_transaction_id};
  return $transaction_id;
}
