
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
#### and Demeter::Atoms in a way that can be displayed in the response
#### box of WebAtoms
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
use Demeter::Constants qw($NUMBER);
use Demeter::StrTypes qw( Element );
use Chemistry::Elements qw(get_symbol get_Z);
use File::Basename;
use File::Copy;
use List::Util qw(max);
use List::MoreUtils; # not importing "any" to avoid collision with Dancer's "any"
use Safe;
use HTTP::Tiny;

$SIG{__WARN__} = sub {accumulate($_[0])};

our $VERSION = '1';

our $atoms    = Demeter::Atoms->new;
our $warning_messages = q{};
our $output   = 'feff';
our $fversion = 8;
$atoms->feff_version($fversion);
our $maxsites = 4;

get '/' => sub {

  my $problems = q{};
  my $response = q{};

  my $e = [];
  my $x = [];
  my $y = [];
  my $z = [];
  my $t = [];
  my $nsites = $maxsites;
  my $icore  = 0;
  my $feffv  = q{};

  my $add     = param('add');
  my $reset   = param('reset');
  my $compute = param('co');
  my $file    = param('file');
  my $url     = param('url');
  my $form    = param('form');

  my $hashref = params;
  my $nparams = keys(%$hashref);

  # user just uploaded a file or fetched a URL
  if (defined($file) and $file) {
    $nsites = $#{$atoms->sites};
    $nsites = 4 if $nsites == -1;
    foreach my $i (0 .. $nsites) { # need to jigger sites into the form the template expects
      if ($atoms->sites->[$i]) {
	($e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]) = split(/\|/, $atoms->sites->[$i]);
      } else {
	($e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]) = (q{},0,0,0,q{});
      }
    };

  # user supplied a URL
  } elsif (defined($url)) {
    $file = fetch_url($url);	# URL copied to local upload directory
    if (not $file) {
      $problems = "- Unable to download " . param('urlfail') . " or file is not an atoms.inp file\n";
    };
    $nsites = $#{$atoms->sites};
    $nsites = 4 if $nsites == -1;
    foreach my $i (0 .. $nsites) { # need to jigger sites into the form the template expects
      if ($atoms->sites->[$i]) {
	($e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]) = split(/\|/, $atoms->sites->[$i]);
      } else {
	($e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]) = (q{},0,0,0,q{});
      }
    };

  # user just tried to read an unreadable/unusable local file or URL
  } elsif (defined(param('urlfail'))) {
    $problems = "- Unable to download " . param('urlfail') . " or file is not an atoms.inp file\n";

  # user just clicked on the Reset button
  } elsif (defined($reset)) {
    $atoms->clear;

  # user just clicked on the 'Add a site' button
  } elsif (defined($add)) {
    $nsites = $#{$atoms->sites};
    foreach my $i (0 .. $nsites) { # need to jigger sites into the form the template expects
      if ($atoms->sites->[$i]) {
	($e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]) = split(/\|/, $atoms->sites->[$i]);
      } else {
	($e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]) = (q{},0,0,0,q{});
      }
    };

  # the form contents just got posted and we are redirected here
  } elsif (defined($form)) {
    $problems = $atoms->message_buffer;
    $nsites = $#{$atoms->sites};
    $nsites = 4 if $nsites == -1;
    ($e, $x, $y, $z, $t)= ([], [], [], [], []);
    foreach my $i (0 .. $nsites) { # need to jigger sites into the form the template expects
      if ($atoms->sites->[$i]) {
	($e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]) = split(/\|/, $atoms->sites->[$i]);
      } else {
	($e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]) = (q{},0,0,0,q{});
      }
    };
    $file ||= join('-', List::MoreUtils::uniq(@$e));
    $file =~ s{\-+\z}{};
  } else {
    $atoms->clear;
  };

  ## begin collecting error text as needed
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


  ## begin constructing the response text according to the current state of things

  # problems found while reading the crystal data
  if ($problems) {
    $response = $problems;
    $output = "trouble";

  # adding a site or resetting, response should be blank
  } elsif (defined($add) or defined($reset)) {
    $response = q{};

  # response text contains problems found while processing crystal data
  } elsif ($atoms->cell->group->warning) {
    $response = $atoms->cell->group->warning;
    $output = "trouble";

  # the user has asked to see the diagnostic text
  } elsif ($output eq 'object') {
    $response = $atoms->serialization;
    $additional .= $warning_messages;
    $additional = join("\n", map {' *!!! ' . $_} (split(/\n/, $additional))) . "\n\n" if ($additional !~ m{\A\s*\z});
    $response = $additional . $response;
    $warning_messages = q{};

  # the normal state of things -- post the feff.inp file or other output
  } elsif ($#{$atoms->sites} > -1) {
    $feffv = ($output eq 'feff') ? $output.$fversion : $output;
    $response = $atoms->Write($feffv);
    $additional .= $warning_messages;
    $additional = join("\n", map {' *!!! ' . $_} (split(/\n/, $additional))) . "\n\n" if ($additional !~ m{\A\s*\z});
    $response = $additional . $response;
    $warning_messages = q{};

  # the user is visiting the page for the first time
  } else {
    $response = $atoms->message_buffer;
    $atoms->message_buffer(q{});
    ##$response = $atoms.$/;
  };

  ## an additional site was requested
  $nsites = $#{$atoms->sites}+1;
  $nsites = 4 if $nsites < 4;
  if ($add) {
    ++$nsites;
    ++$maxsites;
    push @$e, 'H';
    push @$x,  0;
    push @$y,  0;
    push @$z,  0;
    push @$t,  q{};
  };

  ## figure out the default file name for saving the response
  #my $style = $atoms->feff_version . $atoms->ipot_style;
  my $style = '8' . $atoms->ipot_style;
  my $outfile = $output;
  if ($output =~ m{atoms|feff|p1}) {
    $outfile .= '.inp';
  #} elsif ($output =~ m{trouble}) {
  #  $outfile .= '.txt';
  } else {
    $outfile .= '.txt';
  };

  ## make the title text for the generated web page look pretty
  if (defined($file) and ($file !~ m{\A\s*\z})) {
    $file = ' - ' . $file;
  };

  ## make sure the correct site is selected as the absorber
  foreach my $i (0 .. $#{$e}) {
    $icore = $i if (defined(lc($t->[$i])) and defined($atoms->core) and (lc($t->[$i]) eq lc($atoms->core)) or
		    defined(lc($t->[$i])) and defined($atoms->core) and (lc($e->[$i]) eq lc($atoms->core)));
  };
  $icore = 0 if ((not defined($e->[$icore])) or ($e->[$icore] =~ m{\A\s*\z}));

  #####################
  # post the new page #
  #####################
  template 'index', {dversion  => $Demeter::VERSION,
		     waversion => $VERSION,
		     nsites    => max($nsites,$maxsites),
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
		     file      => $file,
		     outfile   => $outfile,
		     response  => $response,
		    };
};


post '/atomsinp' => sub {

  my $e = [];
  my $x = [];
  my $y = [];
  my $z = [];
  my $t = [];
  my $nsites = 4;
  my $feffv  = q{};
  my $problems = q{};
  $atoms->message_buffer(q{});

  #####################################
  # retrieve values from the web page #
  #####################################

  ## lattice constants, numbers
  my $a      = param('a')	|| 0;
  my $b      = param('b')	|| 0;
  my $c      = param('c')	|| 0;
  my $alpha  = param('al')	|| 90;
  my $beta   = param('be')	|| 90;
  my $gamma  = param('ga')	|| 90;

  my @shift  = (param('sx')||0, param('sy')||0, param('sz')||0);

  ## radii, numbers
  my $rclus  = param('rc')	|| 9;
  my $rmax   = param('rm')	|| 5;
  my $rscf   = param('rs')	|| 4;

  my $space  = param('sp')	|| q{};

  ## string options
  my $edge   = param('ed')	|| 'k';
  my $style  = param('st')	|| '8elements';
  my ($v, $s) = (8, 'elements');
  if ($style =~ m{\A([68])(elements|sites|tags)}i) {
    ($v, $s) = ($1, $2);
  };
  $output = param('ou') || 'feff';
  $fversion = $v;

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

  my $count = 50; # try to figure out from the form data how many sites are defined
  while ($count > -1) {
    if (defined(param('e'.$count))) {
      $nsites = $count+1;
      last;
    };
    --$count;
  };

  $atoms->clear_sites;
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

    if ($e->[$i] and (not is_Element(get_symbol($e->[$i])))) {
      $site_problems .= sprintf("- Symbol for site %d is not a valid element symbol (was $e->[$i])\n", $i+1);
    }
    ;
    ($val, $p) = check_number($x->[$i], 0, sprintf("x coordinate for site %d", $i+1), 1);
    $site_problems .= $p;
    $x->[$i] = $val;
    ($val, $p) = check_number($y->[$i], 0, sprintf("y coordinate for site %d", $i+1), 1);
    $site_problems .= $p;
    $y->[$i] = $val;
    ($val, $p) = check_number($z->[$i], 0, sprintf("z coordinate for site %d", $i+1), 1);
    $site_problems .= $p;
    $z->[$i] = $val;

    $e->[$i] = get_symbol($e->[$i]);
    if ($site_problems) {
      $problems .= $site_problems;
    } elsif (is_Element($e->[$i])) {
      my $this = join("|",$e->[$i], $x->[$i], $y->[$i], $z->[$i], $t->[$i]);
      $atoms->push_sites($this);
      if ($i == $core) {
	$atoms->core($t->[$i]);
      };
    };
  };
  if ($atoms->core =~ m{\A\s*\z}) {
    foreach my $i (0 .. $nsites-1) {
      if ($t->[$i] !~ m{\A\s*\z}) {
	$atoms->core($t->[$i]);
	last;
      };
    };
  };

  $problems .= " - You have not specified a space group symbol.\n" if ($space    =~ m{\A\s*\z});
  $problems .= " - You have not specified lattice constants.\n"    if ($atoms->a == 0);
  $atoms->message_buffer($problems);

  redirect '/?form=1';
};


#####################################################################################################
# localfile route, read the provided filename, load data into an Atoms object, reroute to main page #
# example found at http://perlmaven.com/uploading-files-with-dancer2                                #
#####################################################################################################
post '/fromdisk' => sub {
  my $data = request->upload('lfile');
  if (not $data) {
    redirect '/';
    return;
  };

  ## make sure the uploads directory exists
  #my $dir = path(config->{appdir}, 'uploads');
  #mkdir $dir if not -e $dir;
  my $dir = File::Spec->tmpdir();

  ## copy the file to the server's disk space
  my $path = path($dir, $data->basename);
  $data->link_to($path);

  $atoms->clear;
  if ($path =~ m{cif\z}i) {
    $atoms->cif($path);
  } else {
    if (Demeter->is_atoms($path)) {
      $atoms->file($path);
    } else {
      unlink $path;
      redirect '/?urlfail='.$data->basename;
    };
  };
  ## redirect with the name of the file in the server's diskspace
  unlink $path;
  redirect '/?file='.$data->basename;
};


######################################################
# this is the workhorse for the fetch and url routes #
######################################################
sub fetch_url {
  my ($url) = @_;

  ## fetch the content provided by the URL
  my $payload;
  my $response = HTTP::Tiny->new->get($url);
  if ($response->{success}) {
    $payload = $response->{content};
  } else {
    return 0;
  };
  my $file = basename($url);

  ## make sure the uploads directory exists
  #my $dir = path(config->{appdir}, 'uploads');
  #mkdir $dir if not -e $dir;
  my $dir = File::Spec->tmpdir();

  ## write the URL content to a local file
  my $path = path($dir, $file);
  open(my $I, '>', $path);
  print $I $payload;
  close $I;

  ## import the URL content into a Demeter::Atoms object
  $atoms->clear;
  if ($url =~ m{cif\z}i) {
    $atoms->cif($path);
  } else {
    if (Demeter->is_atoms($path)) {
      $atoms->file($path);
    } else {
      return 0;
    };
  };

  ## clean up and done
  unlink $path;
  return $file;
};


## callback for $SIG{__WARN__}
sub accumulate {
  $warning_messages .= $_[0];
};


## safely evaluate a "number" like 1/2 into a float
sub _interpret {
  my ($str) = @_;
  my $cpt = new Safe;
  my $retval = $cpt->reval($str);
  return $retval;
};

## verify that $number can be interpreted as an integer or a float,
## optionally checking if it is negative, returning a sensible default
## if not a number
sub check_number {
  my ($number, $default, $prefix, $negok) = @_;
  my $problem = q{};
  if ($number !~ m{\A$NUMBER\z}) {
    $problem = " - $prefix was not a number (was $number)\n";
  } elsif (($number < 0) and (not $negok)) {
    $problem .= " - $prefix was negative (was $number)\n";
  } else {
    $default = $number;
  };
  return ($default, $problem);
};

true;
