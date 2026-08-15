#!/usr/bin/env perl

# sigilmd -- marker-based content insertion for README.md
#
# Grammar:
#   <!--[[ name ]]-->TOML-subset body<!--/-->      declares a table
#   <!--[[ $table.key ]]-->...<!--/-->              inserts a literal value
#   <!--[[ @$table.key ]]-->...<!--/-->             inserts a file's contents
#   <!--[[ @$a.b$c.d ]]-->...<!--/-->               chained: concatenate, then treat as file
#   <!--[[ $a.b$c.d ]]-->...<!--/-->                chained: concatenate, insert literally
#
# See README.md in this repo for the full spec.

use strict;
use warnings;
use Getopt::Long qw(GetOptions);

my $file   = 'README.md';
my $config = '';
my $check  = 0;

GetOptions(
    'file=s'   => \$file,
    'config=s' => \$config,
    'check'    => \$check,
) or die "sigilmd: bad arguments\n";

die "sigilmd: file not found: $file\n" unless -e $file;

my $original = slurp($file);
my $content  = $original;

# ---------------------------------------------------------------------------
# Locate every <!--[[ ... ]]--> opening marker, in order, with byte offsets.
# ---------------------------------------------------------------------------

my @markers;
while ($content =~ /<!--\[\[\s*(.*?)\s*\]\]-->/gs) {
    push @markers, {
        raw        => $1,
        open_start => $-[0],
        open_end   => $+[0],
    };
}

# For each marker, find its closer (<!--/-->) in the window up to the next
# marker's start (or EOF). If none is found, this is a first run.
for my $i (0 .. $#markers) {
    my $m           = $markers[$i];
    my $window_end  = ($i < $#markers) ? $markers[$i + 1]{open_start} : length($content);
    my $window      = substr($content, $m->{open_end}, $window_end - $m->{open_end});

    if ($window =~ /<!--\/-->/) {
        $m->{body_end}  = $m->{open_end} + $-[0];
        $m->{close_end} = $m->{open_end} + $+[0];
        $m->{body}      = substr($content, $m->{open_end}, $m->{body_end} - $m->{open_end});
        $m->{has_close} = 1;
    }
    else {
        $m->{has_close} = 0;
        $m->{body}      = '';
    }

    # Is there non-whitespace text before the marker on the same source line?
    # Governs whether generated content is spliced inline or as its own block
    # -- e.g. "Version: <!--[[ ... ]]-->" stays on one line, a marker alone
    # on its own line gets its content on separate lines.
    my $prev_nl     = rindex($content, "\n", $m->{open_start} - 1);
    my $line_prefix = substr($content, $prev_nl + 1, $m->{open_start} - $prev_nl - 1);
    $m->{inline}    = ($line_prefix =~ /\S/) ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Pass 1: classify every marker and collect declared tables.
# ---------------------------------------------------------------------------

my $ident = qr/[A-Za-z_][A-Za-z0-9_]*/;
my %tables;

for my $m (@markers) {
    my $raw = $m->{raw};

    if ($raw =~ /^$ident$/) {
        $m->{type} = 'declare';
        my $name = $raw;
        die "sigilmd: table '$name' has no closing marker (<!--/-->)\n"
            unless $m->{has_close};
        die "sigilmd: table '$name' is declared more than once\n"
            if exists $tables{$name};
        $tables{$name} = parse_toml_body($m->{body}, $name);
    }
    elsif ($raw =~ /^\@?(?:\$$ident\.$ident)+$/) {
        $m->{type} = 'reference';
    }
    elsif ($raw =~ /^badge(?:-row)?:/ || $raw =~ /^badge-row$/) {
        # sigilbadges' own marker syntax (<!--[[ badge: ... ]]--> / <!--[[
        # badge-row: ... ]]-->) shares this exact <!--[[ ]]--> bracket
        # convention with no namespace to tell tools apart. Left untouched
        # -- unlike the fallback below, this shape is unambiguous (sigilmd
        # has no colon-prefixed marker of its own), so skipping it can't
        # mask a real sigilmd typo.
        $m->{type} = 'foreign';
    }
    elsif ($raw =~ /^pdf(?:-gallery)?:/) {
        # pdf-preview's own marker syntax (<!--[[ pdf: ... ]]--> / <!--[[
        # pdf-gallery: ... ]]-->) -- same rationale as the badge: case
        # above: unambiguous, sigilmd has no marker starting with 'pdf'.
        $m->{type} = 'foreign';
    }
    else {
        my $hint = ($raw =~ /^$ident\.$ident$/) ? " -- did you mean '\$$raw'?" : '';
        die "sigilmd: unrecognized marker '<!--[[ $raw ]]-->'$hint\n";
    }
}

# Optional external config file, merged into the same table namespace.
if ($config) {
    die "sigilmd: config file not found: $config\n" unless -e $config;
    my %external = parse_toml_file(slurp($config), $config);
    for my $name (keys %external) {
        die "sigilmd: table '$name' is declared in both $file and $config\n"
            if exists $tables{$name};
        $tables{$name} = $external{$name};
    }
}

# ---------------------------------------------------------------------------
# Pass 2: resolve every reference marker. Splice back-to-front so earlier
# offsets stay valid as the string is mutated.
# ---------------------------------------------------------------------------

my @refs = grep { $_->{type} eq 'reference' } @markers;

for my $m (reverse @refs) {
    my $raw     = $m->{raw};
    my $is_file = ($raw =~ s/^\@//) ? 1 : 0;

    my @tokens   = $raw =~ /\$($ident)\.($ident)/g;
    my $resolved = '';

    for (my $j = 0; $j < @tokens; $j += 2) {
        my ($table, $key) = @tokens[$j, $j + 1];
        die "sigilmd: undefined table '\$$table' referenced in '<!--[[ $m->{raw} ]]-->'\n"
            unless exists $tables{$table};
        die "sigilmd: undefined key '$key' in table '$table' referenced in '<!--[[ $m->{raw} ]]-->'\n"
            unless exists $tables{$table}{$key};
        $resolved .= $tables{$table}{$key};
    }

    my $generated;
    if ($is_file) {
        die "sigilmd: file not found: '$resolved' (referenced by '<!--[[ $m->{raw} ]]-->')\n"
            unless -e $resolved;
        $generated = slurp($resolved);
        $generated =~ s/\s+\z//;
    }
    else {
        $generated = $resolved;
    }

    my $replacement = $m->{inline} ? $generated : "\n$generated\n";
    $replacement .= '<!--/-->' unless $m->{has_close};

    my $splice_start = $m->{open_end};
    my $splice_end    = $m->{has_close} ? $m->{body_end} : $m->{open_end};
    substr($content, $splice_start, $splice_end - $splice_start) = $replacement;
}

# ---------------------------------------------------------------------------
# Write or check.
# ---------------------------------------------------------------------------

if ($check) {
    if ($content ne $original) {
        print "sigilmd: $file is out of date -- run without --check to regenerate\n";
        exit 1;
    }
    print "sigilmd: $file is up to date\n";
    exit 0;
}

if ($content ne $original) {
    write_file($file, $content);
    print "sigilmd: wrote $file\n";
}
else {
    print "sigilmd: $file already up to date\n";
}

exit 0;

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "sigilmd: cannot read $path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined $data ? $data : '';
}

sub write_file {
    my ($path, $data) = @_;
    open my $fh, '>', $path or die "sigilmd: cannot write $path: $!\n";
    print {$fh} $data;
    close $fh;
    return;
}

# Parses a declare-block body: blank lines and #-comments are skipped, every
# other line must be   key = "value"   with no escape sequences supported.
sub parse_toml_body {
    my ($body, $table_name) = @_;
    my %kv;
    my $line_no = 0;
    for my $line (split /\n/, $body) {
        $line_no++;
        next if $line =~ /^\s*$/;
        next if $line =~ /^\s*#/;
        if ($line =~ /^\s*($ident)\s*=\s*"([^"\\]*)"\s*$/) {
            $kv{$1} = $2;
        }
        else {
            die "sigilmd: malformed line in table '$table_name' (line $line_no): $line\n";
        }
    }
    return \%kv;
}

# Parses a standalone TOML file: [table] headers followed by key = "value"
# lines, same subset rules as embedded declare blocks.
sub parse_toml_file {
    my ($text, $path) = @_;
    my %tables;
    my $current;
    my $line_no = 0;
    for my $line (split /\n/, $text) {
        $line_no++;
        next if $line =~ /^\s*$/;
        next if $line =~ /^\s*#/;
        if ($line =~ /^\s*\[($ident)\]\s*$/) {
            $current = $1;
            die "sigilmd: table '$current' is declared more than once in $path\n"
                if exists $tables{$current};
            $tables{$current} = {};
        }
        elsif ($line =~ /^\s*($ident)\s*=\s*"([^"\\]*)"\s*$/) {
            die "sigilmd: key '$1' outside of any [table] in $path (line $line_no)\n"
                unless defined $current;
            $tables{$current}{$1} = $2;
        }
        else {
            die "sigilmd: malformed line in $path (line $line_no): $line\n";
        }
    }
    return %tables;
}
