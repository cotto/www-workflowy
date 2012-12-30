#! env perl

package WWW::Workflowy::Op;

use Moose::Role;

has wf => (
  is => 'ro',
  isa => 'WWW::Workflowy',
  required => 1,
);

has projectid => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

#requires 'update_tree';
requires 'gen_push_poll_data';

1;
