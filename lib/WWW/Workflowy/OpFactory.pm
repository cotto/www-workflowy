package WWW::Workflowy::OpFactory;

use WWW::Workflowy::Op::Create;
use WWW::Workflowy::Op::Edit;

use Moose;

has wf => (
  is => 'rw',
  isa => 'WWW::Workflowy',
  required => 1,
);

has registry => (
  is => 'rw',
  isa => 'HashRef[Str]',
  default =>  sub { {} },
);

sub BUILD {
  my ($self) = @_;
  $self->registry->{'create'} = 'WWW::Workflowy::Op::Create';
  $self->registry->{'edit'}   = 'WWW::Workflowy::Op::Edit';
}

sub get_op {
  my ($self, $op_name, $op_args) = @_;
  $op_args->{wf} = $self->wf;
  $self->registry->{$op_name}->new($op_args);
}

1;
