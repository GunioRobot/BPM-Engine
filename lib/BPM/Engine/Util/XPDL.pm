package BPM::Engine::Util::XPDL;
BEGIN {
    $BPM::Engine::Util::XPDL::VERSION   = '0.001';
    $BPM::Engine::Util::XPDL::AUTHORITY = 'cpan:SITETECH';
    }

use strict;
use warnings;
use File::Spec ();
use File::ShareDir ();
use File::Basename ();
use XML::LibXML;
use XML::LibXML::XPathContext;
use XML::LibXML::Simple ();
use BPM::XPDL;
use BPM::Engine::Types qw/Exception/;
use BPM::Engine::Exceptions qw/throw_model throw_install throw_param/;
use Scalar::Util qw/blessed/;
use parent qw/Exporter/;
our @EXPORT_OK = qw/xml_doc xml_hash xpdl_doc xpdl_hash/;
our %EXPORT_TAGS = (all => [@EXPORT_OK]);

sub xml_doc {
    my $arg = shift or throw_param error => "Empty file, string or IO handle (xml_doc)";

    my $parser = XML::LibXML->new;
    my $doc = undef;

    eval {
        if(ref($arg) eq 'SCALAR') {
            $doc = eval { $parser->parse_string($$arg); };
            die "Invalid XML from string: $@" if $@;
            }
        elsif(blessed($arg) && $arg->isa('IO::Handle')) {
            $doc = eval { $parser->parse_fh($arg); };
            die "Invalid XML from io handle: $@" if $@;
            }
        elsif(!ref($arg)) {
            throw_param error => "Invalid XML: Empty file name" unless $arg;
            unless(-f $arg) {
                $arg = File::Basename::fileparse($arg);
                throw_param error => "File '$arg' not found";
                }
            $doc = eval { $parser->parse_file($arg); };
            die "Invalid XML from file: $@" if $@;
            }
        else {
            throw_param error => "Invalid argument ref '$arg'";
            }
        };
    if(my $err = $@) {
        $err->rethrow() if(is_Exception($err));
        throw_model error => $err;
        }

    return $doc;
    }

sub xml_hash {
    my $arg = shift or throw_param error => "Empty file, string or IO handle (xml_hash)";

    my $xmldata = XML::LibXML::Simple::XMLin($arg, ForceArray => [qw/
        ExtendedAttribute FormalParameter DataField ActualParameter
        Participant Application Responsible
        WorkflowProcess Activity Transition TransitionRestriction
        /],
      NormaliseSpace => 2,
      ValueAttr => [ 'GraphConformance' ],
      );

    return $xmldata;
    }

sub xpdl_doc {
    my $doc = shift or throw_param error => "Empty file, string or IO handle (xpdl_doc)";

    $doc = xml_doc($doc) unless(ref($doc) eq 'XML::LibXML::Document');

    eval {
        # get XPDL version from xml
        my @nodes = $doc->documentElement->getElementsByTagName('XPDLVersion');
        die "XPDLVersion not defined" unless $nodes[0];
        my $v = $nodes[0]->textContent;
        $v =~ s/(^\s*|\s*$)//g;
        die "XPDL version not set" unless $v;
        die "Unsupported XPDL version $v"
            unless(grep { $v == $_ } qw/1.0 2.0 2.1 2.2/);
        $v =~ s/\./_/;

        # clean up modeler-proprietary elements and attributes
        my @vnodes = $doc->documentElement->getElementsByTagName('Vendor');
        if($vnodes[0] && $vnodes[0]->textContent =~ /BizAgi/) {
            _clean_bizagi_xml($doc);
            }

        # validate against schema since BPM::XPDL's validation isn't informative
        my $schema_file = _xpdl_spec($v);
        my $schema = XML::LibXML::Schema->new(location => $schema_file);

        eval { $schema->validate($doc); };

        if(my $err = $@) {
            if(ref($err) eq 'XML::LibXML::Error') {
                die "Non-conformant XML: " . $err->message .
                 " in file " . File::Basename::fileparse($err->file) .
                 " (schema " . File::Basename::fileparse($schema_file) . ")" .
                 ($err->line ? ' line ' . $err->line : '');
                #die $@ if $@->level > 2;
                }
            else {
                die $@;
                }
            }
        };

    if(my $err = $@) {
        $err->rethrow() if(is_Exception($err));
        throw_model error => $err;
        }

    return $doc;
    }

sub xpdl_hash {
    my $arg = shift or throw_param error => "Empty file, string or IO handle (xpdl_hash)";

    my $doc  = xpdl_doc($arg);
    my $xpdl;
    eval {
        $xpdl = (BPM::XPDL->from($doc))[1];
        };
    if($@) {
        die "BPM::XPDL error: $@";
        }

    return $xpdl;
    }

# remove non-conformant elements and attributes generated by BizAgi modeler
sub _clean_bizagi_xml {
    my $xmldoc = shift;

    _remove_attributes($xmldoc, 'ConnectorGraphicsInfo', 'FromPort', 'ToPort');
    _remove_attributes($xmldoc, 'Package', 'OnlyOneProcess');

    # Association is missing a required Object element before
    # ConnectorGraphicsInfos, and may contain non-valid ExtendedAttributes.
    # Other elements are proprietary to BizAgi

    my $xc = XML::LibXML::XPathContext->new($xmldoc);
    $xc->registerNs('xpdl', 'http://www.wfmc.org/2008/XPDL2.1');

    my @els = (
        'IsForCompensationSpecified',
        'RequiredForStartSpecified',
        'ProducedAtCompletionSpecified',
        'Associations/Association/ConnectorGraphicsInfos',
        'Associations/Association/ExtendedAttributes',
        'Artifacts/Artifact/Documentation'
        );
    foreach my $tag(@els) {
        _remove_elements($xmldoc, $xc, $tag);
        }
    }

sub _remove_attributes {
    my ($xmldoc, $tag, @attr) = @_;

    my @nodes = $xmldoc->getElementsByTagName($tag);
    foreach my $node(@nodes) {
        foreach(@attr) {
            $node->removeAttribute($_);
            }
        }
    }

sub _remove_elements {
    my ($xmldoc, $xc, $tag) = @_;
    my (@nodes) = ();
    if($tag =~ /\//) {
        my $xpath = '//xpdl:Package/xpdl:' . join('/xpdl:', split('\/', $tag));
        @nodes = $xc->findnodes($xpath);
        }
    else {
        @nodes = $xmldoc->getElementsByTagName($tag);
        }
    foreach my $node(@nodes) {
        my $parent = $node->parentNode;
        $parent->removeChild($node);
        }
    }

sub _xpdl_spec {
    my $version = shift;

    my $fname = "XPDL_$version.xsd";
    my $file;

    eval {
        # suppress warnings from File::ShareDir feeding uninitialized dir to
        # File::Spec's catfile() when dist not installed.
        # no warnings 'uninitialized' doesn't work here.
        local $SIG{__WARN__} = sub {};
        $file = File::ShareDir::dist_file('BPM-Engine', "schemas/$fname");
        };

    if($@ =~ /Failed to find shared file/) {
        my ($volume, $directory, $name) = File::Spec->splitpath(__FILE__);
        $file = File::Spec->catpath(
            $volume, $directory, "../../../../share/schemas/$fname"
            );
        unless(-e $file) {
            throw_install error => "Schema '$fname' not found in shared dirs";
            }
        unless ( -r $file) {
            throw_install
                error => "Schema '$fname' cannot be read, no read permissions";
            }
        }
    elsif($@) {
        throw_install error => "Schema '$fname' not found in shared dirs: $@";
        }

    return $file;
    }

1;
__END__

=pod

=head1 NAME

BPM::Engine::Util::XPDL - XPDL parsing helper functions

=head1 VERSION

0.001

=head1 SYNOPSIS

    use BPM::Engine::Util::XPDL ':all';

    $data = xpdl_hash($input);

    say $data->{WorkflowProcesses}->[0]->{Id};

=head1 DESCRIPTION

This module provides helper functions for parsing of XPDL files and strings.

=head2 Parameter INPUT

The first parameter to any function should be the XML message to be translated
into a Perl structure.  Choose one of the following:

=over 4

=item A filename or URL

If the filename contains no directory components, the function will look for the
file in the current directory.

  $ref = xpdl_hash('/etc/params.xml');

Note, the filename C<< - >> (dash) can be used to parse from STDIN.

=item A scalar reference to an XML string

A string containing XML will be parsed directly.

  my $string = '<Some>Thing</Some>';
  $doc = xml_doc(\$string);

=item An IO::Handle object

An IO::Handle object will be read to EOF and its contents parsed. eg:

  $fh  = IO::File->new('./xpdl/workflows.xpdl');
  $doc = xml_doc($fh);

=back

=head1 EXPORTS

None of the functions are exported by default. The C<:all> key exports all
functions.

=head2 xpdl_hash

    my $data = xpdl_hash($input);
    say $data->{WorkflowProcesses}->[0]->{Id};

The result of C<xpdl_doc()> parsed into a hash by L<BPM::XPDL|BPM::XPDL>. The
resulting data hash represents the XPDL document.

This is presumably the only function you'll need from this module.

=head2 xml_hash

    my $data = xml_hash($input);
    say $data->{WorkflowProcesses}->[0]->{Id};

A 'lightweight' parsing of XPDL-like XML strings. Useful for testing. Example:

    my $string = qq!
    <Package>
    <WorkflowProcesses>
        <WorkflowProcess Id="OrderPizza" Name="Order Pizza">
            <Activities>
                <Activity Id="PlaceOrder" />
                <Activity Id="WaitForDelivery" />
                <Activity Id="PayPizzaGuy" />
            </Activities>
            <Transitions>
                <Transition Id="1" From="PlaceOrder" To="WaitForDelivery"/>
                <Transition Id="2" From="WaitForDelivery" To="PayPizzaGuy"/>
            </Transitions>
        </WorkflowProcess>
    </WorkflowProcesses>
    </Package>!;

    my $data = xml_hash($string);

    say $data->{WorkflowProcesses}->[0]->{Id}; # prints 'OrderPizza'

This function will possibly be deprecated in the near future.

=head2 xml_doc

    $doc = xml_doc($input);

Parses the given file (or URL), string, or input stream into a DOM tree.

Returns a L<XML::LibXML::Document|XML::LibXML::Document> object.

=head2 xpdl_doc

Parses the given file (or URL), string, or input stream (by calling
C<xml_doc()>) and does some checks on the document, specifically:

=over 4

=item

Verify that the XPDL version in the document is supported;

=item

Clean up modeler-proprietary elements and attributes for XPDL generated by the
L<http://bizagi.com|Bizagi BPM modeler>.

=item

Validate the document against the XPDL schema

=back

Returns a L<XML::LibXML::Document|XML::LibXML::Document> object.


=head1 DEPENDENCIES

=over 4

=item * L<File::ShareDir>

=item * L<XML::LibXML|XML::LibXML>

=item * L<XML::LibXML::XPathContext|XML::LibXML::XPathContext>

=item * L<XML::LibXML::Simple|XML::LibXML::Simple>

=item * L<BPM::XPDL|BPM::XPDL>

=item * L<Sub::Exporter|Sub::Exporter>

=back

=head1 AUTHOR

Peter de Vos <sitetech@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2010, 2011 Peter de Vos C<< <sitetech@cpan.org> >>.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.

=cut
