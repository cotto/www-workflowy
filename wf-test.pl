#! env perl

use strict;
use feature qw/say/;
use Data::Dumper;
use Data::DPath qw/dpath/;
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

say "logging out";
$wf->log_out();
say "done logging out";


