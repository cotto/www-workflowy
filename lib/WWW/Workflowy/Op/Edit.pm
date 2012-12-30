package WWW::Workflowy::Op::Edit;
use Moose;

with 'WWW::Workflowy::Op';

has name => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has description => (
  is => 'ro',
  isa => 'Str',
  default => sub { '' },
);

sub gen_push_poll_data {
  my ($self) = @_;
  my $pp_data = { 
    type => 'edit',
    data => {
      projectid => $self->projectid,
      name => $self->name,
      description => $self->description,
    },
    undo_data => {
    },
    client_timestamp => $self->wf->_client_timestamp(),
  };

  return $pp_data;
}

1;
