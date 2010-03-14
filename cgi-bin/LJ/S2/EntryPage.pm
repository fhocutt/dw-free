#!/usr/bin/perl
#
# This code was forked from the LiveJournal project owned and operated
# by Live Journal, Inc. The code has been modified and expanded by
# Dreamwidth Studios, LLC. These files were originally licensed under
# the terms of the license supplied by Live Journal, Inc, which can
# currently be found at:
#
# http://code.livejournal.org/trac/livejournal/browser/trunk/LICENSE-LiveJournal.txt
#
# In accordance with the original license, this code and all its
# modifications are provided under the GNU General Public License.
# A copy of that license can be found in the LICENSE file included as
# part of this distribution.


use strict;
package LJ::S2;

use Carp;

sub EntryPage
{
    my ($u, $remote, $opts) = @_;

    my $get = $opts->{'getargs'};

    my $p = Page($u, $opts);
    $p->{'_type'} = "EntryPage";
    $p->{'view'} = "entry";
    $p->{'comment_pages'} = undef;
    $p->{'comments'} = [];
    $p->{'comment_pages'} = undef;

    # setup viewall options
    my ($viewall, $viewsome) = (0, 0);
    if ( $remote ) {
        # we don't log here, as we don't know what entry we're viewing yet.
        # the logging is done when we call EntryPage_entry below.
        ( $viewall, $viewsome ) =
            $remote->view_priv_check( $u, $get->{viewall} );
    }

    my ($entry, $s2entry) = EntryPage_entry($u, $remote, $opts);
    return if $opts->{'suspendeduser'};
    return if $opts->{'suspendedentry'};
    return if $opts->{'readonlyremote'};
    return if $opts->{'readonlyjournal'};
    return if $opts->{'handler_return'};
    return if $opts->{'redir'};

    $p->{'multiform_on'} = $entry->comments_manageable_by($remote);

    my $itemid = $entry->jitemid;
    my $permalink = $entry->url;
    my $style_arg = LJ::viewing_style_args( %$get );

    if ($u->should_block_robots || $entry->should_block_robots) {
        $p->{'head_content'} .= LJ::robot_meta_tags();
    }
    if ($LJ::UNICODE) {
        $p->{'head_content'} .= '<meta http-equiv="Content-Type" content="text/html; charset='.$opts->{'saycharset'}."\" />\n";
    }
    
    my $prev_url = S2::Builtin::LJ::Entry__get_link( $opts->{ctx}, $s2entry, "nav_prev" )->{url};
    $p->{head_content} .= qq{<link rel="prev" href="$prev_url" />\n} if $prev_url;
    
    my $next_url = S2::Builtin::LJ::Entry__get_link( $opts->{ctx}, $s2entry, "nav_next" )->{url};
    $p->{head_content} .= qq{<link rel="next" href="$next_url" />\n} if $next_url;

    # canonical link to the entry or comment thread
    $p->{head_content} .= LJ::canonical_link( $permalink, $get->{thread} );

    # quickreply js libs
    LJ::need_res(qw(
                    js/core.js
                    js/dom.js
                    js/json.js
                    js/template.js
                    js/ippu.js
                    js/lj_ippu.js
                    js/userpicselect.js
                    js/httpreq.js
                    js/hourglass.js
                    js/inputcomplete.js
                    stc/ups.css
                    stc/lj_base.css
                    js/datasource.js
                    js/selectable_table.js
                    )) if LJ::is_enabled('userpicselect') && $remote && $remote->can_use_userpic_select;

    LJ::need_res(qw(
                    js/x_core.js
                    js/quickreply.js
                    js/browserdetect.js
                    js/thread_expander.js
                    ));

    $p->{'entry'} = $s2entry;
    LJ::Hooks::run_hook('notify_event_displayed', $entry);

    # add the comments
    my $view_arg = $get->{'view'} || "";
    my $flat_mode = ($view_arg =~ /\bflat\b/);
    my $view_num = ($view_arg =~ /(\d+)/) ? $1 : undef;

    my %userpic;
    my %user;
    my $copts = {
        'flat' => $flat_mode,
        'thread' => ($get->{'thread'} >> 8),
        'page' => $get->{'page'},
        'view' => $view_num,
        'userpicref' => \%userpic,
        'userref' => \%user,
        # user object is cached from call just made in EntryPage_entry
        'up' => LJ::load_user($s2entry->{'poster'}->{'user'}),
        'viewall' => $viewall,
        'expand_all' => $opts->{expand_all},
    };

    my $userlite_journal = UserLite($u);

    # Only load comments if commenting is enabled on the entry
    my @comments;
    if ($p->{'entry'}->{'comments'}->{'enabled'}) {
        @comments = LJ::Talk::load_comments($u, $remote, "L", $itemid, $copts);
    }

    my $tz_remote;
    if ($remote) {
        my $tz = $remote->prop("timezone");
        $tz_remote = $tz ? eval { DateTime::TimeZone->new( name => $tz); } : undef;
    }

    my $pics = LJ::Talk::get_subjecticons()->{'pic'};  # hashref of imgname => { w, h, img }
    my $convert_comments = sub {
        my ($self, $destlist, $srclist, $depth) = @_;

        foreach my $com (@$srclist) {
            my $pu = $com->{'posterid'} ? $user{$com->{'posterid'}} : undef;

            my $dtalkid = $com->{'talkid'} * 256 + $entry->anum;
            my $text = $com->{'body'};
            if ($get->{'nohtml'}) {
                # quote all non-LJ tags
                $text =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
            }

            LJ::CleanHTML::clean_comment(\$text, { 'preformatted' => $com->{'props'}->{'opt_preformatted'},
                                                   'anon_comment' => !$pu || ( $pu->is_identity && !$u->trusts_or_has_member( $pu ) ),
                                               });

            # local time in mysql format to gmtime
            my $datetime = DateTime_unix($com->{'datepost_unix'});
            my $datetime_remote = $tz_remote ? DateTime_tz($com->{'datepost_unix'}, $tz_remote) : undef;
            my $seconds_since_entry = $com->{'datepost_unix'} - $entry->logtime_unix;
            my $datetime_poster = DateTime_tz($com->{'datepost_unix'}, $pu);

            my $threadroot_url;

            my ($edited, $edit_url, $editreason, $edittime, $edittime_remote, $edittime_poster);
            if ($com->{_loaded}) {
                my $comment = LJ::Comment->new($u, jtalkid => $com->{talkid});

                $edited = $comment->is_edited;
                $edit_url = LJ::Talk::talkargs($comment->edit_url, $style_arg);
                if ($edited) {
                    $editreason = LJ::ehtml( $comment->edit_reason );
                    $edittime = DateTime_unix($comment->edit_time);
                    $edittime_remote = $tz_remote ? DateTime_tz($comment->edit_time, $tz_remote) : undef;
                    $edittime_poster = DateTime_tz($comment->edit_time, $pu);
                }

                $threadroot_url = $comment->threadroot_url( LJ::viewing_style_args( %$get ) ) if $com->{parenttalkid};
            }

            my $subject_icon = undef;
            if (my $si = $com->{'props'}->{'subjecticon'}) {
                my $pic = $pics->{$si};
                $subject_icon = Image("$LJ::IMGPREFIX/talk/$pic->{'img'}",
                                      $pic->{'w'}, $pic->{'h'}) if $pic;
            }

            my $comment_userpic;
            my $comment_userpic_style = $opts->{ctx}->[S2::PROPS]->{comment_userpic_style};
            if ( ( my $pic = $userpic{$com->{picid}} ) && ( $comment_userpic_style ne 'off' ) )  {
                my $width = $pic->{width};
                my $height = $pic->{height};
                
                if ( $comment_userpic_style eq 'small' )
                {
                    $width = $width / 2;
                    $height = $height / 2;
                }

                $comment_userpic = Image_userpic( $com->{upost}, $com->{picid}, $com->{props}->{picture_keyword}, 
                                                  $width, $height );
            }

            my $reply_url = LJ::Talk::talkargs($permalink, "replyto=$dtalkid", $style_arg);

            my $par_url;

            # in flat mode, promote the parenttalkid_actual
            if ($flat_mode) {
                $com->{'parenttalkid'} ||= $com->{'parenttalkid_actual'};
            }

            if ($com->{'parenttalkid'}) {
                my $dparent = ($com->{'parenttalkid'} << 8) + $entry->anum;
                $par_url = LJ::Talk::talkargs($permalink, "thread=$dparent", $style_arg) . LJ::Talk::comment_anchor( $dparent );
            }

            my $poster;
            if ($com->{'posterid'}) {
                if ($pu) {
                    $poster = UserLite($pu);
                } else {
                    # I can't determine where this code is called, if it ever is?  so for now,
                    # let's spit out a backtrace so we can figure out how this case happens.  we need
                    # to fix it since the journal_type is wrong in some cases.
                    # FIXME: watch logs
                    Carp::cluck "LJ::S2::EntryPage faked a UserLite; userpost=$com->{userpost}:";
                    
                    $poster = {
                        '_type' => 'UserLite',
                        'username' => $com->{'userpost'},
                        'user' => $com->{'userpost'},
                        'name' => $com->{'userpost'},  # we don't have this, so fake it
                        'journal_type' => 'P',         # fake too, but only people can post, so correct
                    };
                }
            }

            # Comment Posted Notice
            my ($last_talkid, $last_jid) = LJ::get_lastcomment();
            my $commentposted = "";
            $commentposted = 1
                 if ($last_talkid == $dtalkid && $last_jid == $remote->{'userid'});

            my $s2com = {
                '_type' => 'Comment',
                'journal' => $userlite_journal,
                'metadata' => {
                    'picture_keyword' => $com->{'props'}->{'picture_keyword'},
                },
                'permalink_url' => "$permalink?thread=$dtalkid" . LJ::Talk::comment_anchor( $dtalkid ),
                'reply_url' => $reply_url,
                'poster' => $poster,
                'replies' => [],
                'subject' => LJ::ehtml($com->{'subject'}),
                'subject_icon' => $subject_icon,
                'talkid' => $dtalkid,
                'text' => $text,
                'userpic' => $comment_userpic,
                'time' => $datetime,
                'system_time' => $datetime, # same as regular time for comments
                'edittime' => $edittime,
                'editreason' => $editreason,
                'tags' => [],
                'full' => $com->{'_loaded'} ? 1 : 0,
                'depth' => $depth,
                'parent_url' => $par_url,
                threadroot_url => $threadroot_url,
                'screened' => $com->{'state'} eq "S" ? 1 : 0,
                'frozen' => $com->{'state'} eq "F" ? 1 : 0,
                'deleted' => $com->{'state'} eq "D" ? 1 : 0,
                'link_keyseq' => [ 'delete_comment' ],
                'anchor' => LJ::Talk::comment_htmlid( $dtalkid ),
                'dom_id' => LJ::Talk::comment_htmlid( $dtalkid ),
                'comment_posted' => $commentposted,
                'edited' => $edited ? 1 : 0,
                'time_remote' => $datetime_remote,
                'time_poster' => $datetime_poster,
                'seconds_since_entry' => $seconds_since_entry,
                'edittime_remote' => $edittime_remote,
                'edittime_poster' => $edittime_poster,
                'edit_url' => $edit_url,
            };

            # don't show info from suspended users
            # FIXME: ideally the load_comments should only return these
            # items if there are children, otherwise they should be hidden entirely
            if ($pu && $pu->is_suspended && !$viewsome) {
                $s2com->{'text'} = "";
                $s2com->{'subject'} = "";
                $s2com->{'full'} = 0;
                $s2com->{'subject_icon'} = undef;
                $s2com->{'userpic'} = undef;
            }

            # Conditionally add more links to the keyseq
            my $link_keyseq = $s2com->{'link_keyseq'};
            push @$link_keyseq, $s2com->{'screened'} ? 'unscreen_comment' : 'screen_comment';
            push @$link_keyseq, $s2com->{'frozen'} ? 'unfreeze_thread' : 'freeze_thread';
            push @$link_keyseq, "watch_thread" if LJ::is_enabled('esn');
            push @$link_keyseq, "unwatch_thread" if LJ::is_enabled('esn');
            push @$link_keyseq, "watching_parent" if LJ::is_enabled('esn');
            unshift @$link_keyseq, "edit_comment" if LJ::is_enabled('edit_comments');

            # always populate expand url; let get_link sort out whether this link should be printed or not
            # the value of expand_url is not directly exposed via s2. It is used by the get_link backend function
            $s2com->{expand_url} = LJ::Talk::talkargs( $permalink, "thread=$dtalkid", $style_arg ) . LJ::Talk::comment_anchor( $dtalkid );
            $s2com->{thread_url} = $s2com->{expand_url} if @{$com->{children}};

            # add the poster_ip metadata if remote user has
            # access to see it.
            $s2com->{'metadata'}->{'poster_ip'} = $com->{'props'}->{'poster_ip'} if
                ($com->{'props'}->{'poster_ip'} && $remote &&
                 ($remote->{'userid'} == $entry->posterid ||
                  LJ::can_manage($remote, $u) || $viewall));

            $s2com->{metadata}->{imported_from} = $com->{props}->{imported_from}
                if $com->{props}->{imported_from};

            push @$destlist, $s2com;

            $self->($self, $s2com->{'replies'}, $com->{'children'}, $depth+1);
        }
    };
    $p->{'comments'} = [];
    $convert_comments->($convert_comments, $p->{'comments'}, \@comments, 1);

    # prepare the javascript data structure to put in the top of the page
    # if the remote user is a manager of the comments
    my $do_commentmanage_js = $p->{'multiform_on'} && LJ::is_enabled('commentmanage', $remote);

    # print comment info
    {
        my $canAdmin = LJ::can_manage($remote, $u) ? 1 : 0;
        my $canSpam = LJ::sysban_check( 'spamreport', $u->user ) ? 0 : 1;
        my $formauth = LJ::ejs(LJ::eurl(LJ::form_auth(1)));

        my $cmtinfo = {
            form_auth => $formauth,
            journal   => $u->user,
            canAdmin  => $canAdmin,
            canSpam   => $canSpam,
            remote    => $remote ? $remote->user : undef,
        };

        my $recurse = sub {
            my ($self, $array) = @_;

            foreach my $i (@$array) {
                my $cmt = LJ::Comment->new($u, dtalkid => $i->{talkid});

                my $has_threads = scalar @{$i->{'replies'}};
                my $poster = $i->{'poster'} ? $i->{'poster'}{'user'} : "";
                my @child_ids = map { $_->{'talkid'} } @{$i->{'replies'}};
                $cmtinfo->{$i->{talkid}} = {
                    rc     => \@child_ids,
                    u      => $poster,
                    parent => $cmt->parent ? $cmt->parent->dtalkid : undef,
                    full   => ($i->{full}),
                };
                $self->($self, $i->{'replies'}) if $has_threads;
            }
        };

        $recurse->($recurse, $p->{'comments'});

        my $js = "<script>\n// don't crawl this.  read http://www.livejournal.com/developer/exporting\n";
        $js .= "var LJ_cmtinfo = " . LJ::js_dumper($cmtinfo) . "\n";
        $js .= '</script>';
        $p->{'LJ_cmtinfo'} = $js if $opts->{'need_cmtinfo'};
        $p->{'head_content'} .= $js;
    }

    LJ::need_res(qw(
                    js/commentmanage.js
                    ));

    $p->{'_picture_keyword'} = $get->{'prop_picture_keyword'};

    $p->{'viewing_thread'} = $get->{'thread'} ? 1 : 0;

    # default values if there were no comments, because
    # LJ::Talk::load_comments() doesn't provide them.
    if ($copts->{'out_error'} eq 'noposts' || scalar @comments < 1) {
        $copts->{'out_pages'} = $copts->{'out_page'} = 1;
        $copts->{'out_items'} = 0;
        $copts->{'out_itemfirst'} = $copts->{'out_itemlast'} = undef;
    }

    $p->{'comment_pages'} = ItemRange({
        'all_subitems_displayed' => ($copts->{'out_pages'} == 1),
        'current' => $copts->{'out_page'},
        'from_subitem' => $copts->{'out_itemfirst'},
        'num_subitems_displayed' => scalar @comments,
        'to_subitem' => $copts->{'out_itemlast'},
        'total' => $copts->{'out_pages'},
        'total_subitems' => $copts->{'out_items'},
        '_url_of' => sub {
            my $sty = $flat_mode ? "view=flat&" : "";
            return "$permalink?${sty}page=" . int($_[0]) .
                ($style_arg ? "&$style_arg" : '');
        },
    });

    return $p;
}

sub EntryPage_entry
{
    my ($u, $remote, $opts) = @_;

    my $get = $opts->{'getargs'};

    my $r = $opts->{'r'};
    my $uri = $r->uri;

    my ($ditemid, $itemid);
    my $entry = $opts->{ljentry};  # only defined in named-URI case.  otherwise undef.

    unless ($entry || $uri =~ /(\d+)\.html/) {
        $opts->{'handler_return'} = 404;
        return;
    }

    $entry ||= LJ::Entry->new($u, ditemid => $1);

    unless ($entry->correct_anum) {
        $opts->{'handler_return'} = 404;
        return;
    }

    $ditemid = $entry->ditemid;
    $itemid  = $entry->jitemid;

    my $pu = $entry->poster;

    my $userlite_journal = UserLite($u);
    my $userlite_poster  = UserLite($pu);

    # do they have the viewall priv?
    my $canview = $get->{viewall} && $remote && $remote->has_priv( "canview" );
    my ($viewall, $viewsome) = (0, 0);
    if ($canview) {
        ( $viewall, $viewsome ) =
            $remote->view_priv_check( $u, $get->{viewall}, 'entry', $itemid );
    }

    # check using normal rules
    unless ($entry->visible_to($remote, $canview)) {
        if ($remote) {
            $opts->{'handler_return'} = 403;
            return;
        } else {
            my $host = $r->headers_in->{Host};
            my $args = scalar $r->args;
            my $querysep = $args ? "?" : "";
            my $redir = LJ::eurl("http://$host$uri$querysep$args");
            $opts->{'redir'} = "$LJ::SITEROOT/?returnto=$redir&errmsg=notloggedin";
            return;
        }
    }

    if ( $pu && $pu->is_suspended && ! $viewsome ) {
        $opts->{'suspendeduser'} = 1;
        return;
    }

    if ($entry && $entry->is_suspended_for($remote)) {
        $opts->{'suspendedentry'} = 1;
        return;
    }

    my $replycount = $entry->prop("replycount");
    my $nc = "";
    $nc .= "nc=$replycount" if $replycount && $remote && $remote->{'opt_nctalklinks'};

    my $style_arg = LJ::viewing_style_args( %$get );
    
    # load the userpic; include the keyword selected by the user
    # as a backup for the alttext
    my $pickw = LJ::Entry->userpic_kw_from_props($entry->props);
    my $userpic = Image_userpic($pu, $entry->userpic ? $entry->userpic->picid : 0, $pickw);

    my $permalink = $entry->url;
    my $linkurl = LJ::Talk::talkargs( $permalink, $style_arg );
    my $readurl = LJ::Talk::talkargs( $permalink, $nc, $style_arg );
    my $posturl = LJ::Talk::talkargs( $permalink, "mode=reply", $style_arg );

    my $comments = CommentInfo({
        'read_url' => $readurl,
        'post_url' => $posturl,
        'permalink_url' => $linkurl,
        'count' => $replycount,
        'maxcomments' => ( $replycount >= $u->count_maxcomments ) ? 1 : 0,
        'enabled' => ($viewall || ($u->{'opt_showtalklinks'} eq "Y" && !$entry->prop("opt_nocomments"))) ? 1 : 0,
        'screened' => ($entry->prop("hasscreened") && $remote && LJ::can_manage($remote, $u)) ? 1 : 0,
    });
    $comments->{show_postlink} = $comments->{enabled} && $get->{mode} ne 'reply';
    $comments->{show_readlink} = $comments->{enabled} && ($replycount || $comments->{screened}) && $get->{mode} eq 'reply';

    # load tags
    my @taglist;
    {
        my $tag_map = $entry->tag_map;
        while (my ($kwid, $kw) = each %$tag_map) {
            push @taglist, Tag($u, $kwid => $kw);
        }
        LJ::Hooks::run_hooks('augment_s2_tag_list', u => $u, jitemid => $itemid, tag_list => \@taglist);
        @taglist = sort { $a->{name} cmp $b->{name} } @taglist;
    }

    my $subject = $entry->subject_html;
    my $event = $entry->event_html;
    if ($get->{'nohtml'}) {
        # quote all non-LJ tags
        $subject =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
        $event   =~ s{<(?!/?lj)(.*?)>} {&lt;$1&gt;}gi;
    }

    if ($opts->{enable_tags_compatibility} && @taglist) {
        $event .= LJ::S2::get_tags_text($opts->{ctx}, \@taglist);
    }

    if ($entry->security eq "public") {
        $LJ::REQ_GLOBAL{'text_of_first_public_post'} = $event;

        if (@taglist) {
            $LJ::REQ_GLOBAL{'tags_of_first_public_post'} = [map { $_->{name} } @taglist];
        }
    }

    my $s2entry = Entry($u, {
        'subject' => $subject,
        'text' => $event,
        'dateparts' => LJ::alldatepart_s2($entry->eventtime_mysql),
        'system_dateparts' => LJ::alldatepart_s2($entry->logtime_mysql),
        'security' => $entry->security,
        'adult_content_level' => $entry->adult_content_calculated || $u->adult_content_calculated,
        'allowmask' => $entry->allowmask,
        'props' => $entry->props,
        'itemid' => $ditemid,
        'comments' => $comments,
        'journal' => $userlite_journal,
        'poster' => $userlite_poster,
        'tags' => \@taglist,
        'new_day' => 0,
        'end_day' => 0,
        'userpic' => $userpic,
        'permalink_url' => $permalink,
    });

    return ($entry, $s2entry);
}

1;
