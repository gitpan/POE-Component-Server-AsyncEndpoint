package POE::Component::Server::AsyncEndpoint::WebServer;

use warnings;
use strict;
use POE::Component::Server::HTTP;
use CGI ":standard";

sub new {

    my $class = shift;
    my $args  = shift;

    my $port;

    if ( ref($args) eq 'HASH' ){
        $port    = $args->{port};
    }

    return undef unless $port;

    # Web interface init

    my $aliases = POE::Component::Server::HTTP->new(
        Port => $port,
        ContentHandler => {
            '/'      => \&root_handler,
            '/post/' => \&post_handler,
        }
    );

    my $self = {
        aliases   => $aliases,
    };
    bless $self, $class;


    return $self;


}


# root handler
sub root_handler {
    my ( $request, $response ) = @_;
    $response->code(RC_OK);
    $response->content
        (start_html("Sample Form") .
             start_form
                 (-method  => "post",
                  -action  => "/post",
                  -enctype => "application/x-www-form-urlencoded",
              ) .
                  "Foo: " . textfield("foo") . br() .
                      "Bar: " .
                          popup_menu
                              (-name   => "bar",
                               -values => [ 1, 2, 3, 4, 5 ],
                               -labels => {
                                   1 => 'one',
                                   2 => 'two',
                                   3 => 'three',
                                   4 => 'four',
                                   5 => 'five'
                               }
                           ) . br() .
                               submit( "submit", "submit" ) .
                                   end_form() .
                                       end_html());

    return RC_OK;
}

# post handler
sub post_handler {
    my ( $request, $response ) = @_;

    # This code creates a CGI query.
    my $q;
    if ( $request->method() eq 'POST' ) {
        $q = new CGI( $request->content );
    }
    else {

        $request->uri() = ~/\?(.+$)/;

        if ( defined($1) ) {
            $q = new CGI($1);
        } else {
            $q = new CGI;
        }

        # The rest of this handler displays the values encapsulated by the
        # object.
        $response->code(RC_OK);
        $response->content(
            start_html("Posted Values") .
                "Foo = " . $q->param("foo") . br() .
                    "Bar = " . $q->param("bar") .
                        end_html()
                    );

        return RC_OK;
    }

}


1;

__END__

=head1 NAME

POE::Component::Server::AsyncEndpoint::WebServer

=head1 DESCRIPTION

This is the web interface to the aes server. With it, you will be able
to start and stop Endpoints as well as view status and logs. It might
offer some simple web services for these functions as well. It's not
yet developed, but the skeleton is in place.

=head1 SEE ALSO

L<POE::Component::Server::AsyncEndpoint>

=head1 AUTHOR

Alejandro Imass <ait@p2ee.org>
Alejandro Imass <aimass@corcaribe.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Alejandro Imass / Corcaribe Tecnología C.A. for the P2EE Project

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

