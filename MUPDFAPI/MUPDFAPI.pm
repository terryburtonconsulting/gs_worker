#
# MUPDFAPI.pm - Perl XS bindings for MuPDF PDF-to-SVG conversion
#
# Copyright (c) 2026 Terry Burton
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

package MUPDFAPI;

our $VERSION = '0.1';

use strict;
use warnings;
use XSLoader;

XSLoader::load('MUPDFAPI', $VERSION);

# Convert a PDF to SVG.  MuPDF's SVG device emits the root <svg> element's
# width/height attributes as unitless numbers (equivalent to PostScript
# points but without a unit suffix), which most renderers would interpret
# as user units — displaying the barcode ~25% smaller than the intended
# physical size.  Append "pt" to both attributes so the physical meaning
# is unambiguous.  The viewBox stays unitless (required by the SVG spec)
# so internal coordinate calculations are unaffected.
sub pdf_to_svg {
    my ($ctx, $pdf_bytes) = @_;
    my $svg = _pdf_to_svg_raw($ctx, $pdf_bytes);
    $svg =~ s/(<svg[^>]*\swidth=")([\d.]+)(")/${1}${2}pt${3}/;
    $svg =~ s/(<svg[^>]*\sheight=")([\d.]+)(")/${1}${2}pt${3}/;
    return $svg;
}

1;
__END__

=head1 NAME

MUPDFAPI - Perl XS bindings for MuPDF PDF-to-SVG conversion

=head1 SYNOPSIS

    use MUPDFAPI;

    my $ctx = MUPDFAPI::new_context();
    my $svg = MUPDFAPI::pdf_to_svg($ctx, $pdf_bytes);
    MUPDFAPI::drop_context($ctx);

=head1 DESCRIPTION

Minimal Perl XS wrapper around MuPDF's C library for converting PDF
documents to SVG.  The context is reusable across multiple conversions.

=head1 FUNCTIONS

=over

=item new_context()

Create a MuPDF context with document handlers registered.  Returns an
opaque context object.  Call once at startup and reuse.

=item pdf_to_svg($context, $pdf_bytes)

Convert raw PDF bytes to SVG.  Returns the SVG as a byte string.  The
root C<< <svg> >> element's C<width> and C<height> attributes carry
explicit C<pt> units so renderers (browsers, Illustrator, Inkscape, etc.)
interpret them as physical PostScript points rather than user units.
Dies on error.

=item _pdf_to_svg_raw($context, $pdf_bytes)

Low-level XS binding.  Returns the unmodified SVG bytes from MuPDF's
SVG writer, with unitless C<width>/C<height> attributes.  Prefer
C<pdf_to_svg> for normal use.

=item drop_context($context)

Free the MuPDF context.  Call during shutdown.

=back

=head1 LICENSE

GNU Affero General Public License v3.

=cut
