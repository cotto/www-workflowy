#! env perl

use strict;
use feature qw/say state/;
use LWP;
use Data::Dumper;
use JSON;
use Data::DPath qw/dpath/;
use URL::Encode qw/url_encode/;
use DateTime;
use Math::EMA;

use lib qw/lib/;
use WWW::Workflowy;


my $username = 'test';
my $password = 'test';

my $wf = WWW::Workflowy->new();

say "logging in...";
unless ($wf->log_in($username, $password)) {
  say "login failed";
  exit;
}
say "done logging in";

say "grabbing tree...";
$wf->get_tree();
say "done grabbing tree";

#say "editing item";
#edit_item($ua, {
#    id => '5a4d3097-72d0-9029-ee63-7653c0624343',
#    name => "I've got a lovely bunch of coconuts.",
#  }, $wf_tree,
#);
#say "trying to create a child";
#create_item($ua, '3fa535e1-06b3-4406-0e75-4ddba7c9d606', {name => "child creation test number the fourth", priority => 2}, $wf_tree);

#log_out($ua); exit;


if (1) {
  my $children = $wf->tree ~~ dpath '//rootProjectChildren//nm[ value =~ /#food-log/ ]/..';
  my $date_weights = [];
  my $wf_list = $wf->tree->{main_project_tree_info}{rootProjectChildren};
  my $ema = Math::EMA->new();
  $ema->alpha = (1 - .2);

  foreach my $child_tree (@$children) {
    my $date = $child_tree->{nm};
    $date =~ s/#food-log //;
    my $weights = $child_tree ~~ dpath '//nm[ value =~ /weight.*\d\d/ ]';
    my $weight = $weights->[0];
    $weight =~ s/[^0-9.]//g;

    $ema->add($weight);
    say "found weight: '$weight'";
    my $avg = sprintf("%.2f", $ema->ema);
    my $delta_ema = sprintf("%.2f", $weight - $avg);
    my $msg = "stats: ewma = $avg, d_ewma = $delta_ema";
    say $msg;

    #say "on $date, weight was $weight";
    my $stats_item = $child_tree ~~ dpath "/ch//nm[value =~ /stats/]/..";
    my $stats_id;
    if (scalar(@$stats_item)) {
      say "found stats item; id is $stats_item->[0]{id}";
      $stats_id = $stats_item->[0]{id};
      if ($stats_item->[0]{nm} eq $msg) {
        say "stats for $date are already current: skipping";
        next;
      }
    }
    else {
      say "no stats item: creating one";
      $stats_id = $wf->create_item($child_tree->{id}, {name => "stats", priority => 999});
    }
    say "updating stats";
    $wf->edit_item({id => $stats_id, name => $msg});
  }
}


#my $parent_id = find_parent_id('de08c6ae-07d9-3043-bce3-a9680aa04e7e', $wf_tree);
#say "parent is $parent_id";

# GOAL:
# * grab the weight info from all #food-log entries
# * mangle it into a nice list
# * for each day
#   * create a stats item if needed
#   * calculate the 10-day exponentially smoothed average (and whatever else seems expedient)
#   * get the uuid of the stats item
#   * update the contents of the stats item


say "logging out";
$wf->log_out();
say "done logging out";


