#!/usr/bin/env perl

# Test runner for sigilmd.pl. Uses only core modules.

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use File::Basename qw(dirname);
use Cwd qw(abs_path getcwd);
use Test::More;

my $root   = abs_path(dirname(__FILE__) . '/..');
my $script = "$root/sigilmd.pl";

# --- Happy path: fixture-based, first run produces the documented output. ---
{
    my $dir = tempdir(CLEANUP => 1);
    copy("$root/t/fixtures/demo/README.before.md", "$dir/README.md") or die $!;
    mkdir "$dir/assets" or die $!;
    copy("$root/t/fixtures/demo/assets/intro.md", "$dir/assets/intro.md") or die $!;

    my $out = run_in($dir, "perl '$script' --file README.md");
    like($out, qr/wrote README\.md/, 'first run reports it wrote the file');

    my $got      = slurp("$dir/README.md");
    my $expected = slurp("$root/t/fixtures/demo/README.after.md");
    is($got, $expected, 'first-run output matches the documented fixture');

    # --- Idempotency: a second run makes no further changes. ---
    my $out2 = run_in($dir, "perl '$script' --file README.md");
    like($out2, qr/already up to date/, 'second run is a no-op');
    is(slurp("$dir/README.md"), $expected, 'content unchanged after second run');

    # --- --check mode agrees. ---
    my ($check_out, $check_status) = run_with_status($dir, "perl '$script' --file README.md --check");
    is($check_status, 0, '--check exits 0 when up to date');
}

# --- --check mode on a stale file exits non-zero without writing. ---
{
    my $dir = tempdir(CLEANUP => 1);
    write_to("$dir/README.md", qq{<!--[[ config ]]-->\nversion = "1.0"\n<!--/-->\n\n<!--[[ \$config.version ]]-->\n});
    my $before = slurp("$dir/README.md");

    my (undef, $status) = run_with_status($dir, "perl '$script' --file README.md --check");
    isnt($status, 0, '--check exits non-zero on a stale file');
    is(slurp("$dir/README.md"), $before, '--check does not modify the file');
}

# --- Error cases: each must fail loudly with a specific message. ---
my %error_cases = (
    'missing $ on a reference' => [
        qq{<!--[[ config ]]-->\nversion = "1.0"\n<!--/-->\n<!--[[ config.version ]]-->\n<!--/-->\n},
        qr/did you mean '\$config\.version'/,
    ],
    'duplicate table declaration' => [
        qq{<!--[[ config ]]-->\nversion = "1.0"\n<!--/-->\n<!--[[ config ]]-->\nversion = "2.0"\n<!--/-->\n},
        qr/declared more than once/,
    ],
    'reference to an undefined table' => [
        qq{<!--[[ \$ghost.key ]]-->\n<!--/-->\n},
        qr/undefined table '\$ghost'/,
    ],
    'reference to an undefined key' => [
        qq{<!--[[ config ]]-->\nversion = "1.0"\n<!--/-->\n<!--[[ \$config.missing ]]-->\n<!--/-->\n},
        qr/undefined key 'missing'/,
    ],
    'file reference to a path that does not exist' => [
        qq{<!--[[ t ]]-->\nfile = "nope.md"\n<!--/-->\n<!--[[ \@\$t.file ]]-->\n<!--/-->\n},
        qr/file not found: 'nope\.md'/,
    ],
    'declare block with no closing marker' => [
        qq{<!--[[ config ]]-->\nversion = "1.0"\n},
        qr/has no closing marker/,
    ],
    'malformed line inside a table body' => [
        qq{<!--[[ config ]]-->\nversion: "1.0"\n<!--/-->\n},
        qr/malformed line in table 'config'/,
    ],
);

for my $name (sort keys %error_cases) {
    my ($content, $expect) = @{ $error_cases{$name} };
    my $dir = tempdir(CLEANUP => 1);
    write_to("$dir/README.md", $content);
    my ($out, $status) = run_with_status($dir, "perl '$script' --file README.md 2>&1");
    isnt($status, 0, "exits non-zero: $name");
    like($out, $expect, "error message: $name");
}

# --- External config (--config): tables merge with inline declarations. ---
{
    my $dir = tempdir(CLEANUP => 1);
    write_to("$dir/README.md", qq{<!--[[ inline ]]-->\nname = "sigilmd"\n<!--/-->\n<!--[[ \$inline.name ]]-->\n<!--/-->\n<!--[[ \$ext.value ]]-->\n<!--/-->\n});
    write_to("$dir/sigilmd.toml", qq{[ext]\nvalue = "from config"\n});

    my $out = run_in($dir, "perl '$script' --file README.md --config sigilmd.toml");
    like($out, qr/wrote README\.md/, '--config run reports it wrote the file');

    my $got = slurp("$dir/README.md");
    like($got, qr/sigilmd/, 'inline table value resolved');
    like($got, qr/from config/, 'external config table value resolved and merged with inline tables');
}

# --- External config: name collisions and malformed config files are hard errors. ---
my %config_error_cases = (
    'table declared in both file and config' => {
        readme => qq{<!--[[ dup ]]-->\nx = "1"\n<!--/-->\n},
        config => qq{[dup]\nx = "2"\n},
        expect => qr/declared in both/,
    },
    'config file not found' => {
        readme      => '',
        config_path => 'missing.toml',
        expect      => qr/config file not found/,
    },
    'malformed line in config file' => {
        readme => '',
        config => qq{[dup]\nx: "1"\n},
        expect => qr/malformed line in/,
    },
    'key outside any table in config file' => {
        readme => '',
        config => qq{x = "1"\n},
        expect => qr/outside of any \[table\]/,
    },
    'duplicate table inside the config file itself' => {
        readme => '',
        config => qq{[dup]\nx = "1"\n[dup]\ny = "2"\n},
        expect => qr/declared more than once in/,
    },
);

for my $name (sort keys %config_error_cases) {
    my $case        = $config_error_cases{$name};
    my $dir         = tempdir(CLEANUP => 1);
    my $config_path = $case->{config_path} || 'sigilmd.toml';
    write_to("$dir/README.md", $case->{readme});
    write_to("$dir/$config_path", $case->{config}) if defined $case->{config};

    my ($out, $status) = run_with_status($dir, "perl '$script' --file README.md --config $config_path 2>&1");
    isnt($status, 0, "exits non-zero: $name");
    like($out, $case->{expect}, "error message: $name");
}

done_testing();

# --- helpers ---

sub run_in {
    my ($dir, $cmd) = @_;
    my $cwd = getcwd();
    chdir $dir or die $!;
    my $out = `$cmd`;
    chdir $cwd;
    return $out;
}

sub run_with_status {
    my ($dir, $cmd) = @_;
    my $cwd = getcwd();
    chdir $dir or die $!;
    my $out    = `$cmd`;
    my $status = $? >> 8;
    chdir $cwd;
    return ($out, $status);
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub write_to {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
    return;
}
