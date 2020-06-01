use 5.008;
use ExtUtils::MakeMaker;

my $IDIR;
my( $next, @argv );
foreach( @ARGV ) {
    if( $next ) {
        $IDIR = $_;
        last;
    }
    if( /^--include=(.+)/ ) {
        $IDIR=$1;
        last;
    }
    if( /^--include$/ ) {
        $next = 1;
        next;
    }
    push @argv, $_;
}
@ARGV = @argv;

unless( $IDIR ) {
    foreach my $dir ( "/usr/local/include/mupdf",
                      "/usr/include/mupdf" ) {
        next unless -f "$dir/fitz.h";
        print "Found $dir/fitz.h\n";
        $IDIR = $dir;
        # INC needs the parent so that #include <mupdf/fitz.h> works
        $IDIR =~ s|/mupdf$||;
    }
}

unless( $IDIR ) {
    warn "Didn't find mupdf/fitz.h.\nYou must specify the path with CCFLAGS= or --include=\n";
}

my $INC = "-I.";
$INC .= " -I$IDIR" if $IDIR;

WriteMakefile(
    'NAME'              => 'MUPDFAPI',
    'VERSION_FROM'      => 'MUPDFAPI.pm',
    'PREREQ_PM'         => { },
    ($] >= 5.005 ?
      (ABSTRACT_FROM => 'MUPDFAPI.pm',
       AUTHOR     => 'Terry Burton') : ()),
    'LIBS'              => ['-lmupdf'],
    'DEFINE'            => '',
    'INC'               => $INC,
);
