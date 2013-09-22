# Copyright 2013 Nitor Creations Oy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package My::License;

use strict;
use warnings;

BEGIN {
    use Exporter   ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

    $VERSION     = 1.00;
    @ISA         = qw(Exporter);
    @EXPORT      = qw(isLackingProperLicense maintainLicense); # default export list
    #@EXPORT_OK   = qw(isLackingLicense addOrUpdateLicense); # exported if qw(function)
    #%EXPORT_TAGS = ( );     # eg: TAG => [ qw!name1 name2! ],
}
our @EXPORT_OK;

my $EMPTY_LINE_AFTER_HASHBANG = 1;

my %licenseTextCache; # filename => contents
my $author_year;

sub _getLicenseText {
    my $license_text_file = $_[0];
    my $license = $licenseTextCache{$license_text_file};
    unless (defined($license)) {
	open F, '<', $license_text_file or die 'Could not read license file';
	my $sep = $/;
	undef $/;
	$license = <F>;
	$/ = $sep;
	close F;
	$licenseTextCache{$license_text_file} = $license;
    }
    return $license;
}

sub extract_timestamp {
    my $gitdate = $_[0];
    if (defined($gitdate)) {
       $gitdate =~ m!(\d{9,})! and return $1;
    }
    return undef;
}

# transform license into a regexp that matches an existing license
# block ignoring whitespace and with "YEAR" changed to the appropriate
# regexp
# in: "# Copyright YEAR Company Ltd\n\n" out: "\s*# Copyright\s+(\d{4}(?:\s*-\s*\d{4})?)\s+Company\s+Ltd\s*"
sub regexpify_license {
    my ($license) = @_ or die;
    $license =~ s!^\s+!!mg; $license =~ s!\s+$!!mg; # remove heading & trailing whitespace on each line
    $license =~ s{^(?:\h*\v)+}{}s; $license =~ s{(?:\v\h*)+$}{}s; # remove heading & trailing empty lines
    my @parts = split(/(\s+|YEAR)/, $license);
    push @parts, ''; # avoid having to handle final-iteration special cases in for loop
    my $regexp = '\s*'; # compensate for previously removed heading empty lines & whitespace
    for(my $i=0; $i<$#parts; $i+=2) {
	my $verbatim = $parts[$i]; # normal non-whitespace text that is supposed to exist as-is
	$regexp .= quotemeta($verbatim);

	my $special = $parts[$i+1]; # empty, whitespace or "YEAR" which are replaced with regexps
	if ($special eq 'YEAR') {
	    # accept any sensibly formatted set of years and/or year ranges, ignoring whitespace
	    my $year_or_year_range_regexp = '\d{4}(?:\s*-\s*\d{4})?';
	    $special = '('.$year_or_year_range_regexp.'(?:\s*,\s*'.$year_or_year_range_regexp.')*)';
	} elsif(length($special)) {
	    $special = '\s+'; # instead of exact sequence of whitespace characters accept any amount of whitespace
	}
	$regexp .= $special;
    }
    $regexp .= '\s*'; # compensate for previously removed trailing empty lines & whitespace
    return $regexp;
}

# in: "2005, 2007-2009, 2012" out: ( 2005=>1, 2007=>1, 2008=>1, 2009=>1, 2012=>1 )
sub unpack_ranges {
    my $years_str = $_[0];
    my @year_ranges = split(/\s*,\s*/,$years_str);
    my $found = 0;
    my %years;
    for (my $i=0; $i<=$#year_ranges; ++$i) {
	my $year_range = $year_ranges[$i];
	my $low_year;
	my $high_year;
	if ($year_range =~ m!(\d{4})\s*-\s*(\d{4})!) {
	     $low_year = $1;
	    $high_year = $2;
	} else {
	    $low_year = $year_range;
	    $high_year = $year_range;
	}
	$found = 1 if ($low_year <= $author_year && $author_year <= $high_year);
	for (my $y=$low_year; $y<=$high_year; ++$y) {
	    $years{$y} = 1;
	}
    }
    return %years;
}

# in: ( 2005=>1, 2007=>1, 2008=>1, 2009=>1, 2012=>1 ) out: "2005, 2007-2009, 2012"
sub pack_ranges {
    my %years = @_;
    my @years = sort (keys %years, 9999); # 9999 -> avoid having to handle final-iteration special case in for loop
    my @year_ranges = ();
    for (my $i=0; $i<$#years; ) {
	my $j;
	for ($j=1; $i+$j<$#years; ++$j) {
	    last if($years[$i]+$j != $years[$i+$j]);
	}
	push @year_ranges, $j == 1 ? $years[$i] : $years[$i].'-'.($years[$i]+$j-1);
	$i += $j;
    }
    return join(", ", @year_ranges);
}

sub _execute {
    my ($license_text_file, $source_file, $contents, $dry_run) = @_;

    my $author_date = extract_timestamp($ENV{'GIT_AUTHOR_DATE'}) || time();
    my @author_date_fields = localtime($author_date);
    $author_year = $author_date_fields[5] + 1900;

    my $license = _getLicenseText($license_text_file);

    # check for possible hashbang line and temporarily detach it

    my $hashbang = '';
    if ($contents =~ s{^(#!\V+\v)(?:\h*\v)*}{}s) {
	$hashbang = $1;
	if ($EMPTY_LINE_AFTER_HASHBANG) {
	    $hashbang .= "\n";
	}
    }

    # create regexp version of license for relaxed detection of existing license

    my $license_regexp = regexpify_license($license);

    # check for possibly existing license and remove it

    my $years_str;
    if ($contents =~ s!^$license_regexp!!s) { # this removes the license as a side effect
	# license present, construct new $years_str based on currently mentioned years
	return 0 if($dry_run);
	my %years = unpack_ranges($1);
	$years{$author_year} = 1; # add current year to set if not yet there
	$years_str = pack_ranges(%years);

    } else {
	# full license not present - see if any single line of license is
	# present, in which case someone broke the header accidentally
	my @license_line_regexps = map { regexpify_license($_) } grep { m![a-zA-Z]! } split("\n", $license);
	foreach my $license_line_regexp (@license_line_regexps) {
	    if ($contents =~ m!^$license_line_regexp$!m) {
		print STDERR "ERROR: License header broken in ",$source_file," - please fix manually\n";
		return 1;
	    }
	}

	# no license - new list of years is just current year
	return 2 if($dry_run);
	$years_str = $author_year;
    }

    # format new license

    my $newlicense = $license;
    $newlicense =~ s!YEAR!$years_str!g;

    # output

    return 0, $hashbang, $newlicense, $contents;
}

sub isLackingProperLicense {
    my ($license_text_file, $source_file, $contents) = @_;
    return _execute($license_text_file, $source_file, $contents, 1);
}

sub maintainLicense {
    my ($license_text_file, $source_file, $contents) = @_;
    return _execute($license_text_file, $source_file, $contents, 0);
}

1;
