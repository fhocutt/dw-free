#!/usr/bin/perl
#
# DW::Proxy
#
# Functions related to the content proxy used for protecting embedded HTTP
# content.
#
# Authors:
#      Mark Smith <mark@dreamwidth.org>
#
# Copyright (c) 2015 by Dreamwidth Studios, LLC.
#
# This program is free software; you may redistribute it and/or modify it under
# the same terms as Perl itself.  For a copy of the license, please reference
# 'perldoc perlartistic' or 'perldoc perlgpl'.
#

package DW::Proxy;

use strict;
use v5.10;

use Digest::MD5 qw/ md5_hex /;

sub get_url_signature {
    my ( $url ) = @_;
    state $salt;

    unless ( defined $salt ) {
        return undef
            unless $LJ::PROXY_SALT_FILE && -e $LJ::PROXY_SALT_FILE;
        open FILE, $LJ::PROXY_SALT_FILE;
        { local $/ = undef; $salt = <FILE>; }
        close FILE;
    }

    return substr(md5_hex($salt . $url), 0, 12);
}

sub get_proxy_url {
    my ( $url ) = @_;
    return undef unless $LJ::PROXY_URL && substr($url, 0, 7) eq 'http://';

    my $signature = DW::Proxy::get_url_signature($url);
    return undef unless $signature;

    return join('/', $LJ::PROXY_URL, $signature, substr($url, 7));
}

1;
