#! env perl

use strict;
use feature qw/say/;
use LWP;
use Data::Dumper;
use JSON;
use Data::DPath qw/dpath/;
use URL::Encode;


my $username = 'test';
my $password = 'test';

my $ua = LWP::UserAgent->new;
$ua->cookie_jar({});

unless (log_in($ua, $username, $password)) {
  die "couldn't log in.  sad face.";
}

my $wf_tree = get_wf_tree($ua);
die Dumper(\$wf_tree);

edit_item($ua, {
    id => '5a4d3097-72d0-9029-ee63-7653c0624343',
    name => "updated!!!?!!",
    note => "and now it has a note",
  }, $wf_tree,
);



log_out($ua); exit;




my $children = $wf_tree ~~ dpath '//rootProjectChildren//nm[ value =~ /#food-log/ ]/..';
my $date_weights = [];

foreach my $child (@$children) {
  my $date = $child->{nm};
  $date =~ s/#food-log //;
  my $weights = $child ~~ dpath '//nm[ value =~ /^weight/ ]';
  my $weight = $weights->[0];
  $weight =~ s/[^0-9.]//g;
  say "on $date, weight was $weight";
}

# GOAL:
# * grab the weight info from all #food-log entries
# * mangle it into a nice list
# * for each day
#   * create a stats item if needed
#   * calculate the 10-day exponentially smoothed average (and whatever else seems expedient)
#   * get the uuid of the stats item
#   * update the contents of the stats item


log_out($ua);


# creating a new item:
# [{
#   "most_recent_operation_transaction_id":"86354089",
#   "operations":
#   [{
#     "type":"create",
#     "data": {
#       "projectid":"3fa535e1-06b3-4406-0e75-4ddba7c9d606",
#       "parentid":"7b06186f-573a-b443-b66a-12bd28b95743",
#       "priority":1
#     },
#     "undo_data":{},
#     "client_timestamp":1613527
#   },
#   {
#     "type":"move",
#     "data": {
#       "projectid":"3fa535e1-06b3-4406-0e75-4ddba7c9d606",
#       "parentid":"d6e42406-eb99-4b93-b6f0-87dd7eef29ec",
#       "priority":0
#     },
#     "undo_data":{
#       "previous_parentid":"7b06186f-573a-b443-b66a-12bd28b95743",
#       "previous_priority":1,
#       "previous_last_modified":1613527
#     },
#     "client_timestamp":1613527
#   },
#   {
#     "type":"edit",
#     "data": {
#       "projectid":"3fa535e1-06b3-4406-0e75-4ddba7c9d606",
#       "name":"a third item??????"
#     },
#     "undo_data":{
#       "previous_last_modified":1613527,
#       "previous_name":""
#     },
#     "client_timestamp":1613527
#   }],
#   "project_expansions_delta": {
#     "d6e42406":true
#   }
# }] 
  
=item rand_string($len)

Generate a random alnum string of $len characters.

=cut

sub rand_string {
  my $len = shift;
  my $s = join "", map ['0'..'9','A'..'Z','a'..'z']->[rand 62], 1..$len;
  return $s
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
  return $wf_tree;
}


=item edit_item($ua, $item_data, $wf_tree) 

Modify the name and/or notes of an existing item.

=cut

sub edit_item {
  my ($ua, $item_data, $wf_tree) = @_;

  # TODO: deal with parents?
  
  my $req = HTTP::Request->new(POST => 'https://workflowy.com/push_and_poll');
  $req->content_type('application/x-www-form-urlencoded');
  my $client_id = $wf_tree->{client_id};

  # build the push/poll data
  my $push_poll_data = {
    most_recent_operation_transaction_id => '????',
    operations => [
      {
        type => 'edit',
        data => {
          projectid => $item_data->{id},
          name => $item_data->{name},
        },
        undo_data => {
          previous_last_modified => '????',
          previous_name => '????',
        },
        # number of minutes since this client joined + ((client start time in ms - current timestamp in ms) / 60000)
        # client start time can be calculated from client_id
        client_timestamp => '?????',
      }
    ],
  };

  my $push_poll_json = json_encode($push_poll_data);
  my $push_poll_encoded = url_encode($push_poll_json);

  my $req_data = "client_id=$client_id&".
      "client_version=9&".
      "push_poll_id=".rand_str(8)."&".
      "push_poll_data=$push_poll_encoded";
  $req_data = url_encode($req_data);
  
  $req->content($req_data);



# editing an existing thing
#  [{
#    "most_recent_operation_transaction_id":"86362832",
#    "operations":[{
#      "type":"edit",
#      "data":{
#        "projectid":"3fa535e1-06b3-4406-0e75-4ddba7c9d606",
#        "name":"a third item is now even awesomer"
#      },
#      "undo_data":{
#        "previous_last_modified":1613527,
#        "previous_name":"a third item??????"
#      },
#      "client_timestamp":1613541
#    }]
#  }]



  



}
