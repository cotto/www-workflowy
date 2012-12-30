package WWW::Workflowy::Op::Create;
use Moose;

with 'WWW::Workflowy::Op';

has priority => (
  is => 'ro',
  isa => 'Int',
  required => 1,
);

has parentid => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

sub gen_push_poll_data {
  my ($self) = @_;
  my $pp_data = { 
    type => 'create',
    data => {
      projectid => $self->projectid,
      parentid => $self->parentid,
      priority => $self->priority,
    },
    undo_data => {
    },
    client_timestamp => $self->wf->_client_timestamp(),
  };

  return $pp_data;
}

1;
