
#### ===============================================================
#### This causes /neither/ Larch /nor/ Ifeffit to be loaded
#### also forces Demeter to be in web mode very early in startup
BEGIN {
  $ENV{DEMETER_NO_BACKEND} = 1;
  $ENV{DEMETER_MODE} = 'web';
}
#### ===============================================================

#### ===============================================================
#### This is used to capture error messages from Xray::Crystal::Cell
#### in a way that can be displayed in the response box of WebAtoms
BEGIN {
  use Demeter qw(:atoms :ui=web);
}

package Xray::Crystal::Cell;
no warnings 'once';
sub carp {
  $WebAtoms::warning_messages .= $_[0];
};
package Demeter::Atoms;
no warnings 'once';
sub carp {
  $WebAtoms::warning_messages .= $_[0];
};
#### ===============================================================


package WebAtoms;
use Dancer ':syntax';
#use Demeter qw(:atoms);
use Demeter::Constants qw($NUMBER);
use Demeter::StrTypes qw( Element );
use File::Copy;
use List::Util qw(max);
use List::MoreUtils; # not importing "any" to avoid collision with Dancer's "any"
use Safe;
use HTTP::Tiny;

$SIG{__WARN__} = sub {accumulate($_[0])};

our $VERSION = '1';

our $atoms = Demeter::Atoms->new;
our $warning_messages = q{};
our $output = 'feff';

get '/' => sub {

  my $problems = q{};
  my $response = q{};

  my $e = [];
  my $x = [];
  my $y = [];
  my $z = [];
  my $t = [];
  my $nsites = 5;
  my $icore  = 0;
  my $feffv  = q{};

  my $add     = param('add');
  my $reset   = param('reset');
  my $compute = param('compute');

  if (param('keep')) {
    $nsites = $#{$atoms->sites};
    $nsites = 4 if $nsites == -1;
    foreach my $i (0 .. $nsites) {
      next if not $atoms->sites->[$i];
      ($e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]) = split(/\|/, $atoms->sites->[$i]);
    };

  } elsif (defined($reset)) {
    $atoms->clear;

  } else {
    #####################################
    # retrieve values from the web page #
    #####################################

    ## lattics constants, numbers
    my $a      = param('a')	|| 0;
    my $b      = param('b')	|| 0;
    my $c      = param('c')	|| 0;
    my $alpha  = param('alpha')	|| 90;
    my $beta   = param('beta')	|| 90;
    my $gamma  = param('gamma')	|| 90;

    my @shift  = (param('shift_x')||0, param('shift_y')||0, param('shift_z')||0);

    ## radii, numbers
    my $rclus  = param('rclus')	|| 9;
    my $rmax   = param('rmax')	|| 5;
    my $rscf   = param('rscf')	|| 4;

    my $space  = param('space')	|| q{};

    ## string options
    my $edge   = param('edge')	|| 'k';
    my $style  = param('style')	|| '6el';
    my ($v, $s) = (6, 'elements');
    if ($style =~ m{\A([68])(elements|sites|tags)}i) {
      ($v, $s) = ($1, $2);
    };
    $output = param('output') || 'feff';
    $feffv = ($output eq 'feff') ? $output.$v : $output;

    $atoms->clear;


    ##################################################
    # sanitize the values retrived from the web page #
    ##################################################

    my ($val, $p);
    ## lattics constants, numbers
    ($val, $p) = check_number($b, 0, 'Lattice constant b', 0);
    $problems .= $p;
    $atoms->b($val) if $val;

    ($val, $p) = check_number($c, 0, 'Lattice constant c', 0);
    $problems .= $p;
    $atoms->c($val) if $val;

    ($val, $p) = check_number($a, 0, 'Lattice constant a', 0);
    $problems .= $p;
    $atoms->a($val);
    $atoms->b($atoms->a) if ($atoms->b == 0);
    $atoms->c($atoms->a) if ($atoms->c == 0);

    ($val, $p) = check_number($beta,  90, 'Angle beta', 0);
    $problems .= $p;
    $atoms->beta($val);

    ($val, $p) = check_number($gamma, 90, 'Angle gamma', 0);
    $problems .= $p;
    $atoms->gamma($val);

    ($val, $p) = check_number($alpha, 90, 'Angle alpha', 0);
    $problems .= $p;
    $atoms->alpha($val);
    $atoms->beta( $atoms->alpha) if ($atoms->beta  == 0);
    $atoms->gamma($atoms->alpha) if ($atoms->gamma == 0);


    ## shift vector, numbers, must be interpreted e.g. 1/3 -> 0.33333
    @shift = map {_interpret($_)} @shift;
    ($val, $p) = check_number($shift[0], 0, 'Shift vector X coordinate', 1);
    $problems .= $p;
    $shift[0] = $val;
    ($val, $p) = check_number($shift[1], 0, 'Shift vector Y coordinate', 1);
    $problems .= $p;
    $shift[1] = $val;
    ($val, $p) = check_number($shift[2], 0, 'Shift vector Z coordinate', 1);
    $problems .= $p;
    $shift[2] = $val;
    $atoms->shiftvec(\@shift);


    ## radii, numbers
    ($val, $p) = check_number($rclus, 9, 'Cluster size', 0);
    $problems .= $p;
    $atoms->rmax($val) if $val;

    ($val, $p) = check_number($rmax, 5, 'Longest path length', 0);
    $problems .= $p;
    $atoms->rpath($val) if $val;

    ($val, $p) = check_number($rscf, 4, 'Self consistency radius', 0);
    $problems .= $p;
    $atoms->rscf($val) if $val;


    ## lists, strings
    if (List::MoreUtils::any {lc($edge) eq $_} qw(k l1 l2 l3)) {
      $atoms->edge($edge);
    } else {
      $problems .= "- Edge is not one of K, L1, L2, or L3 (was $edge)\n";
    };
    if (List::MoreUtils::any {lc($s) eq $_} qw(elements tags sites)) {
      $atoms->ipot_style($s);
      $atoms->feff_version($v);
    } else {
      $problems .= "- Style is not one of elements, tags, or sites (was $s)\n";
    };

    $atoms->space($space) if defined $space;
    $atoms->cell->space_group($space); # why is this necessary!!!!!  why is the trigger not being triggered?????
    $problems .= sprintf("- %s (was %s)\n", $atoms->cell->group->warning, $space) if $atoms->cell->group->warning;

    ########################################
    # retrieve and sanitize the atoms list #
    ########################################

    my $count = 100;		# try to figure out from the form data how many sites are defined
    while ($count > -1) {
      if (defined(param('e'.$count))) {
	$nsites = $count+1;
	last;
      };
      --$count;
    };

    my $core = param('core') || 0;
    foreach my $i (0 .. $nsites-1) {
      my $site_problems = q{};
      $e->[$i] = param('e'.$i) || q{};
      $x->[$i] = param('x'.$i) || 0;
      $y->[$i] = param('y'.$i) || 0;
      $z->[$i] = param('z'.$i) || 0;
      $t->[$i] = param('t'.$i) || param('e'.$i) || q{};

      $x->[$i] = _interpret($x->[$i]);
      $y->[$i] = _interpret($y->[$i]);
      $z->[$i] = _interpret($z->[$i]);

      if ($e->[$i] and (not is_Element($e->[$i]))) {
	$site_problems .= sprintf("- Symbol for site %d is not a valid element symbol (was $e->[$i])\n", $i+1);
      };
      ($val, $p) = check_number($x->[$i], 0, sprintf("x coordinate for site %d", $i+1), 1);
      $site_problems .= $p;
      $x->[$i] = $val;
      ($val, $p) = check_number($y->[$i], 0, sprintf("y coordinate for site %d", $i+1), 1);
      $site_problems .= $p;
      $y->[$i] = $val;
      ($val, $p) = check_number($z->[$i], 0, sprintf("z coordinate for site %d", $i+1), 1);
      $site_problems .= $p;
      $z->[$i] = $val;


      if ($site_problems) {
	$problems .= $site_problems;
      } elsif (is_Element($e->[$i])) {
	my $this = join("|",$e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]);
	$atoms->push_sites($this);
	$atoms->core($t->[$i]) if ($i == $core);
      };
    };
    $icore = $core;

    #$atoms->populate;
    if (defined($compute)) {
      $problems .= " - You have not specified a space group symbol.\n" if ($space    =~ m{\A\s*\z});
      $problems .= " - You have not specified lattice constants.\n"    if ($a        == 0);
      #$problems .= " - The b lattice constant is 0.\n"                 if ($atoms->b == 0);
      #$problems .= " - The c lattice constant is 0.\n"                 if ($atoms->c == 0);
      #$problems .= " - The alpha angle is 0.\n"                        if ($alpha    == 0);
      #$problems .= " - The beta angle is 0.\n"                         if ($beta     == 0);
      #$problems .= " - The gamma angle is 0.\n"                        if ($gamma    == 0);
    };

  };

  my $additional = q{};

  if ($atoms->cell->group->is_first and $#{$atoms->cell->group->shiftvec} > -1) {
    my $vec = sprintf("(%s, %s, %s)", @{$atoms->cell->group->shiftvec});
    $additional = "
This space group symbol identifies the first standard setting.  You may need to
use a shift vector of

  $vec

If you see multiply occupied positions or if the coordination seems wrong, you
should try using that shift vector.

";
  };


  if ($problems) {
    $response = $problems;
  } elsif (defined($add) or defined($reset)) {
    $response = q{};
  } elsif ($atoms->cell->group->warning) {
    $response = $atoms->cell->group->warning;
  } elsif ($output eq 'object') {
    $response = $atoms->serialization;
    $additional .= $warning_messages;
    $additional = join("\n", map {' *!!! ' . $_} (split(/\n/, $additional))) . "\n\n" if ($additional !~ m{\A\s*\z});
    $response = $additional . $response;
    $warning_messages = q{};
  } elsif ($#{$atoms->sites} > -1) {
    $response = $atoms->Write($feffv);
    $additional .= $warning_messages;
    $additional = join("\n", map {' *!!! ' . $_} (split(/\n/, $additional))) . "\n\n" if ($additional !~ m{\A\s*\z});
    $response = $additional . $response;
    $warning_messages = q{};
  } else {
    $response = q{};
  };


  #####################
  # post the new page #
  #####################
  $nsites = $#{$atoms->sites}+1;
  $nsites = 5 if $nsites < 5;
  if ($add) {
    ++$nsites;
    push @$e, 'H';
    push @$x,  0;
    push @$y,  0;
    push @$z,  0;
  };

  my $style = $atoms->feff_version . $atoms->ipot_style;
  my $outfile = $output;
  if ($output =~ m{atoms|feff|p1}) {
    $outfile .= '.inp';
  } else {
    $outfile .= '.dat';
  };

  template 'index', {dversion  => $Demeter::VERSION,
		     waversion => $VERSION,
		     nsites    => $nsites,
		     space     => $atoms->space,
		     a	       => $atoms->a,
		     b	       => $atoms->b,
		     c	       => $atoms->c,
		     alpha     => $atoms->alpha,
		     beta      => $atoms->beta,
		     gamma     => $atoms->gamma,
		     rclus     => $atoms->rmax,
		     rmax      => $atoms->rpath,
		     rscf      => $atoms->rscf,
		     shift_x   => $atoms->shiftvec->[0],
		     shift_y   => $atoms->shiftvec->[1],
		     shift_z   => $atoms->shiftvec->[2],
		     edge      => $atoms->edge,
		     style     => $style,
		     icore     => $icore,
		     e	       => $e,
		     x	       => $x,
		     y	       => $y,
		     z	       => $z,
		     t	       => $t,
		     outfile   => $outfile,
		     response  => $response};
};


get '/url' => sub {
  my $url = param('url');
  if ($url =~ m{\A\s*\z}) {
    redirect '/?keep=1';
    return;
  };
  fetch_url($url);
  redirect '/?keep=1';
};


## thanks Gabor!  http://perlmaven.com/uploading-files-with-dancer2
post '/upload' => sub {
  my $data = request->upload('file');
  if (not $data) {
    redirect '/?keep=1';
    return;
  };

  my $dir = path(config->{appdir}, 'uploads');
  mkdir $dir if not -e $dir;

  my $path = path($dir, $data->basename);
  $data->link_to($path);

  $atoms->clear;
  if ($path =~ m{cif\z}i) {
    $atoms->cif($path);
  } else {
    $atoms->file($path);
  };
  unlink $path;
  redirect '/?keep=1';
};

post '/fetch' => sub {
  my $url = param('url');
  if ($url =~ m{\A\s*\z}) {
    redirect '/?keep=1';
    return;
  };
  fetch_url($url);
  redirect '/?keep=1';
};

sub fetch_url {
  my ($url) = @_;

  my $payload;
  my $response = HTTP::Tiny->new->get($url);
  if ($response->{success}) {
    $payload = $response->{content};
  }

  my $dir = path(config->{appdir}, 'uploads');
  mkdir $dir if not -e $dir;

  my $path = path($dir, "fromweb");
  open(my $I, '>', $path);
  print $I $payload;
  close $I;
  $atoms->clear;
  if ($url =~ m{cif\z}i) {
    $atoms->cif($path);
  } else {
    $atoms->file($path);
  };
  unlink $path;
};


sub accumulate {
  $warning_messages .= $_[0];
};

sub _interpret {
  my ($str) = @_;
  my $cpt = new Safe;
  my $retval = $cpt->reval($str);
  return $retval;
};

sub check_number {
  my ($number, $default, $prefix, $negok) = @_;
  my $problem = q{};
  if ($number !~ m{\A$NUMBER\z}) {
    $problem = "- $prefix was not a number (was $number)\n";
  } elsif (($number < 0) and (not $negok)) {
    $problem .= "- $prefix was negative (was $number)\n";
  } else {
    $default = $number;
  };
  return ($default, $problem);
};

true;
