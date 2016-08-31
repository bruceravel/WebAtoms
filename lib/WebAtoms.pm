package WebAtoms;
use Dancer ':syntax';
use Demeter qw(:atoms);
use Demeter::Constants qw($NUMBER);
use Demeter::StrTypes qw( Element );

our $VERSION = '0.1';

our $atoms = Demeter::Atoms->new;

get '/' => sub {
  my $a      = param('a')	|| 0;
  my $b      = param('b')	|| 0;
  my $c      = param('c')	|| 0;
  my $alpha  = param('alpha')	|| 90;
  my $beta   = param('beta')	|| 90;
  my $gamma  = param('gamma')	|| 90;
  my $space  = param('space')	|| q{};
  my $edge   = param('edge')	|| 'k';
  my $style  = param('style')	|| 'elements';
  my $output = param('output')	|| 'feff';
  my $rclus  = param('rclus')	|| 9;
  my $rmax   = param('rmax')	|| 5;
  my $rscf   = param('rscf')	|| 3;
  my @shift  = (param('shift_x')||0, param('shift_y')||0, param('shift_z')||0);

  $atoms->clear;

  $atoms->space($space) if defined $space;
  $atoms->a($a)         if defined $a;
  $atoms->b($b)         if defined $b;
  $atoms->c($c)         if defined $c;
  $atoms->alpha($alpha) if defined $alpha;
  $atoms->beta($beta)   if defined $beta;
  $atoms->gamma($gamma) if defined $gamma;
  $atoms->rmax($rclus)  if defined $rclus;
  $atoms->rpath($rmax)  if defined $rmax;
  $atoms->rscf($rscf)   if defined $rscf;
  $atoms->shiftvec(\@shift);

  my $e = [];
  my $x = [];
  my $y = [];
  my $z = [];
  my $t = [];

  my $nsites = 5;
  my $core = param('core') || 0;
  foreach my $i (0 .. $nsites-1) {
    $e->[$i] = param('e'.$i) || q{};
    $x->[$i] = param('x'.$i) || 0;
    $y->[$i] = param('y'.$i) || 0;
    $z->[$i] = param('z'.$i) || 0;
    $t->[$i] = param('t'.$i) || param('e'.$i) || q{};
    if (is_Element($e->[$i])) {
      my $this = join("|",$e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]);
      $atoms->push_sites($this);
    };
    $atoms->core($t->[$i]) if ($i == $core);
  };
  my $response = $atoms->serialization;
  $response = $atoms->Write('feff6') if ($#{$atoms->sites} > -1);



  template 'index', {dversion => $Demeter::VERSION,
		     nsites   => $nsites,
		     space    => $atoms->space,
		     a	      => $atoms->a,
		     b	      => $atoms->b,
		     c	      => $atoms->c,
		     alpha    => $atoms->alpha,
		     beta     => $atoms->beta,
		     gamma    => $atoms->gamma,
		     rclus    => $atoms->rmax,
		     rmax     => $atoms->rpath,
		     rscf     => $atoms->rscf,
		     shift_x  => $atoms->shiftvec->[0],
		     shift_y  => $atoms->shiftvec->[1],
		     shift_z  => $atoms->shiftvec->[2],
		     e	      => $e,
		     x	      => $x,
		     y	      => $y,
		     z	      => $z,
		     t	      => $t,
		     response => $response};
};

true;
