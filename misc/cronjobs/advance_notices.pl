#!/usr/bin/env perl

# Copyright 2008 LibLime
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA

=head1 NAME

advance_notices.pl - cron script to put item due reminders into message queue

=head1 SYNOPSIS

./advance_notices.pl -c

or, in crontab:
0 1 * * * advance_notices.pl -c

=head1 DESCRIPTION

This script prepares pre-due and item due reminders to be sent to
patrons. It queues them in the message queue, which is processed by
the process_message_queue.pl cronjob. The type and timing of the
messages can be configured by the patrons in their "My Alerts" tab in
the OPAC.

=cut

use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use C4::Biblio;
use Koha;
use C4::Context;
use C4::Letters;
use C4::Members;
use C4::Members::Messaging;
use C4::Overdues;
use C4::Circulation qw();
use C4::Dates qw/format_date/;
use C4::Branch qw/GetBranchDetail/;
use Try::Tiny;


# These are defaults for command line options.
my $confirm;                                                        # -c: Confirm that the user has read and configured this script.
# my $confirm     = 1;                                                # -c: Confirm that the user has read and configured this script.
my $nomail;                                                         # -n: No mail. Will not send any emails.
my $mindays     = 0;                                                # -m: Maximum number of days in advance to send notices
my $maxdays     = 30;                                               # -e: the End of the time period
my $fromaddress = C4::Context->preference('KohaAdminEmailAddress'); # -f: From address for the emails
my $verbose     = 0;                                                # -v: verbose
my $itemscontent = join(',',qw( issuedate title barcode author ));
my $use_tt      = 1;                                                # --[no-]use_tt: NoTalking Tech notices

GetOptions( 'c'              => \$confirm,
            'n'              => \$nomail,
            'm:i'            => \$maxdays,
            'f:s'            => \$fromaddress,
            'v'              => \$verbose,
            'itemscontent=s' => \$itemscontent,
            'use-tt!'        => \$use_tt,
       );
my $usage = << 'ENDUSAGE';

This script prepares pre-due and item due reminders to be sent to
patrons. It queues them in the message queue, which is processed by
the process_message_queue.pl cronjob.
See the comments in the script for directions on changing the script.
This script has the following parameters :
	-c Confirm and remove this help & warning
        -m maximum number of days in advance to send advance notices.
        -f from address for the emails. Defaults to KohaAdminEmailAddress system preference
	-n send No mail. Instead, all mail messages are printed on screen. Usefull for testing purposes.
        -v verbose
        -i csv list of fields that get substituted into templates in places
           of the E<lt>E<lt>items.contentE<gt>E<gt> placeholder.  Defaults to
           issuedate,title,barcode,author
        --[no-]use-tt turn on/off potential Talking Tech notices
ENDUSAGE

# Since advance notice options are not visible in the web-interface
# unless EnhancedMessagingPreferences is on, let the user know that
# this script probably isn't going to do much
if ( ! C4::Context->preference('EnhancedMessagingPreferences') ) {
    warn <<'END_WARN';

The "EnhancedMessagingPreferences" syspref is off.
Therefore, it is unlikely that this script will actually produce any messages to be sent.
To change this, edit the "EnhancedMessagingPreferences" syspref.

END_WARN
}

unless ($confirm) {
    print $usage;
    print "Do you wish to continue? (y/n)";
    chomp($_ = <STDIN>);
    exit unless (/^y/i);
	
}

# The fields that will be substituted into <<items.content>>
my @item_content_fields = split(/,/,$itemscontent);

warn 'Talking Tech notices are OFF' if (!$use_tt && $verbose);
warn 'getting upcoming due issues' if $verbose;
my $upcoming_dues = C4::Circulation::GetUpcomingDueIssues( { days_in_advance => $maxdays } );
warn 'found ' . scalar( @$upcoming_dues ) . ' issues' if $verbose;

# hash of borrowernumber to number of items upcoming
# for patrons wishing digests only.
my $upcoming_digest;
my $due_digest;

my $dbh = C4::Context->dbh();
my $sth = $dbh->prepare(<<'END_SQL');
SELECT biblio.*, items.*, issues.*
  FROM issues,items,biblio
  WHERE items.itemnumber=issues.itemnumber
    AND biblio.biblionumber=items.biblionumber
    AND issues.borrowernumber = ?
    AND issues.itemnumber = ?
    AND (TO_DAYS(date_due)-TO_DAYS(NOW()) = ?)
END_SQL

for my $upcoming ( @$upcoming_dues ) {
    warn 'examining ' . $upcoming->{'itemnumber'} . ' upcoming due items' if $verbose;
    # warn( Data::Dumper->Dump( [ $upcoming ], [ 'overdue' ] ) );

    my $letter;
    my $borrower_preferences;
    my @Ttitems;
    if ( 0 == $upcoming->{'days_until_due'} ) {
        # This item is due today. Send an 'item due' message.
        $borrower_preferences = C4::Members::Messaging::GetMessagingPreferences(
          { borrowernumber => $upcoming->{'borrowernumber'},
            message_name   => 'Item Due'
          }
        );
        # warn( Data::Dumper->Dump( [ $borrower_preferences ], [ 'borrower_preferences' ] ) );
        next unless $borrower_preferences;

        if ( $borrower_preferences->{'wants_digest'} ) {
            # cache this one to process after we've run through all of the items.
            push @{$due_digest->{$upcoming->{borrowernumber}}}, $upcoming->{itemnumber};
        } else {
            my $biblio = C4::Biblio::GetBiblioFromItemNumber( $upcoming->{'itemnumber'} );
            my $letter_type = 'DUE';
            $letter = C4::Letters::getletter( 'circulation', $letter_type );
            die "no letter of type '$letter_type' found. Please see sample_notices.sql" unless $letter;
            $sth->execute($upcoming->{'borrowernumber'},$upcoming->{'itemnumber'},'0');
            my $titles = "";
            while ( my $item_info = $sth->fetchrow_hashref()) {
              my @item_info = map { $_ =~ /^date|date$/ ? format_date($item_info->{$_}) : $item_info->{$_} || '' } @item_content_fields;
              $titles .= join("\t",@item_info) . "\n";
            }
        
            $letter = parse_letter( { letter         => $letter,
                                      borrowernumber => $upcoming->{'borrowernumber'},
                                      branchcode     => $upcoming->{'branchcode'},
                                      biblionumber   => $biblio->{'biblionumber'},
                                      itemnumber     => $upcoming->{'itemnumber'},
                                      substitute     => { 'items.content' => $titles }
                                    } );
            $upcoming->{'title'} = $biblio->{'title'};
            push @Ttitems,$upcoming;
            if ($use_tt) {
              C4::Letters::CreateTALKINGtechMESSAGE($upcoming->{'borrowernumber'},\@Ttitems,$letter->{ttcode},'1') if ($letter);
            }
        }
    } else {
        $borrower_preferences = C4::Members::Messaging::GetMessagingPreferences(
          { borrowernumber => $upcoming->{'borrowernumber'},
            message_name   => 'Advance Notice'
          }
        );
        # warn( Data::Dumper->Dump( [ $borrower_preferences ], [ 'borrower_preferences' ] ) );
        next unless $borrower_preferences && exists $borrower_preferences->{'days_in_advance'};
        next unless $borrower_preferences->{'days_in_advance'} == $upcoming->{'days_until_due'};

        if ( $borrower_preferences->{'wants_digest'} ) {
            # cache this one to process after we've run through all of the items.
            push @{$upcoming_digest->{$upcoming->{borrowernumber}}}, $upcoming->{itemnumber};
        } else {
            my $biblio = C4::Biblio::GetBiblioFromItemNumber( $upcoming->{'itemnumber'} );
            my $letter_type = 'PREDUE';
            $letter = C4::Letters::getletter( 'circulation', $letter_type );
            die "no letter of type '$letter_type' found. Please see sample_notices.sql" unless $letter;
            $sth->execute($upcoming->{'borrowernumber'},$upcoming->{'itemnumber'},$borrower_preferences->{'days_in_advance'});
            my $titles = "";
            while ( my $item_info = $sth->fetchrow_hashref()) {
              my @item_info = map { $_ =~ /^date|date$/ ? format_date($item_info->{$_}) : $item_info->{$_} || '' } @item_content_fields;
              $titles .= join("\t",@item_info) . "\n";
            }
        
            $letter = parse_letter( { letter         => $letter,
                                      borrowernumber => $upcoming->{'borrowernumber'},
                                      branchcode     => $upcoming->{'branchcode'},
                                      biblionumber   => $biblio->{'biblionumber'},
                                      itemnumber     => $upcoming->{'itemnumber'},
                                      substitute     => { 'items.content' => $titles }
                                    } );
            $upcoming->{'title'} = $biblio->{'title'};
            push @Ttitems,$upcoming;
            if ($use_tt) {
              C4::Letters::CreateTALKINGtechMESSAGE($upcoming->{'borrowernumber'},\@Ttitems,$letter->{ttcode},'1') if ($letter);
            }
        }
    }

    # Skip the email if an SMS number is available and Talking Tech is in use
    my $borrower = C4::Members::GetMember($upcoming->{'borrowernumber'});
    next if ($borrower->{smsalertnumber} && C4::Context->preference('TalkingTechEnabled'));
    # If we have prepared a letter, send it.
    if ($letter) {
        if ($nomail) {
            local $, = "\f";
            print $letter->{'content'};
        } else {
            my $ccb = try {
                my $ccbcode = C4::Circulation::GetCircControlBranch(
                    pickup_branch => $upcoming->{holdingbranch},
                    item_homebranch => $upcoming->{homebranch},
                    borrower_branch => $upcoming->{branchcode},
                );
                return GetBranchDetail($ccbcode);
            }
            catch {
                return {};
            };

            for my $transport ( @{$borrower_preferences->{transports}} ) {
                C4::Letters::EnqueueLetter({
                    letter => $letter,
                    borrowernumber => $upcoming->{borrowernumber},
                    message_transport_type => $transport,
                    to_address => $borrower->{email},
                    from_address => ($ccb->{branchemail} || $fromaddress || undef),
                });
            }
        }
    }
}

# warn( Data::Dumper->Dump( [ $upcoming_digest ], [ 'upcoming_digest' ] ) );

# Now, run through all the people that want digests and send them

$sth = $dbh->prepare(<<'END_SQL');
SELECT biblio.*, items.homebranch, items.holdingbranch, items.itype, items.barcode, issues.*
  FROM issues,items,biblio
  WHERE items.itemnumber=issues.itemnumber
    AND biblio.biblionumber=items.biblionumber
    AND issues.borrowernumber = ?
    AND (TO_DAYS(date_due)-TO_DAYS(NOW()) = ?)
END_SQL

for my $borrowernumber ( keys %{ $upcoming_digest} ) {
    my @Ttitems;
    my @items = @{$upcoming_digest->{$borrowernumber}};
    my $count = scalar @items;
    my $borrower = C4::Members::GetMember($borrowernumber);
    my $borrower_preferences = C4::Members::Messaging::GetMessagingPreferences( 
         { borrowernumber => $borrowernumber,
           message_name   => 'Advance Notice'
         }
       );
    # warn( Data::Dumper->Dump( [ $borrower_preferences ], [ 'borrower_preferences' ] ) );
    next unless $borrower_preferences; # how could this happen?

    my $letter_type = 'PREDUEDGST';
    my $letter = C4::Letters::getletter( 'circulation', $letter_type );
    die "no letter of type '$letter_type' found. Please see sample_notices.sql" unless $letter;
    $sth->execute($borrowernumber,$borrower_preferences->{'days_in_advance'});
    my $titles = "";
    while ( my $item_info = $sth->fetchrow_hashref()) {
      push (@Ttitems, $item_info);
      my @item_info = map { $_ =~ /^date|date$/ ? format_date($item_info->{$_}) : $item_info->{$_} || '' } @item_content_fields;
      $titles .= join("\t",@item_info) . "\n";
    }
    my $ccb = try {
        my $ccbcode = C4::Circulation::GetCircControlBranch(
            pickup_branch => $Ttitems[0]{holdingbranch},
            item_homebranch => $Ttitems[0]{homebranch},
            borrower_branch => $Ttitems[0]{branchcode},
        );
        return GetBranchDetail($ccbcode);
    }
    catch {
        return {};
    };

    $letter = parse_letter( { letter         => $letter,
                              borrowernumber => $borrowernumber,
                              branchcode     => $borrower->{branchcode},
                              itemnumber     => $items[0],
                              substitute     => { count => $count,
                                                  'items.content' => $titles
                                                }
                         } );
    if ($use_tt) {
      C4::Letters::CreateTALKINGtechMESSAGE($borrowernumber,\@Ttitems,$letter->{ttcode},'1') if ($letter);
    }

    # Skip the email if an SMS number is available and Talking Tech is in use
    next if ($borrower->{smsalertnumber} && C4::Context->preference('TalkingTechEnabled'));
    if ($nomail) {
      local $, = "\f";
      print $letter->{'content'};
    }
    else {
      foreach my $transport ( @{$borrower_preferences->{'transports'}} ) {
        C4::Letters::EnqueueLetter( { letter                 => $letter,
                                      borrowernumber         => $borrowernumber,
                                      to_address => $borrower->{email},
                                      from_address => ($ccb->{branchemail} || $fromaddress || undef),
                                      message_transport_type => $transport } );
      }
    }
}

# Now, run through all the people that want digests and send them
for my $borrowernumber ( keys %{ $due_digest} ) {
    my @Ttitems;
    my @items = @{$due_digest->{$borrowernumber}};
    my $count = scalar @items;
    my $borrower = C4::Members::GetMember($borrowernumber);
    my $borrower_preferences = C4::Members::Messaging::GetMessagingPreferences( 
         { borrowernumber => $borrowernumber,
           message_name   => 'Item Due'
         }
       );
    # warn( Data::Dumper->Dump( [ $borrower_preferences ], [ 'borrower_preferences' ] ) );
    next unless $borrower_preferences; # how could this happen?

    my $letter_type = 'DUEDGST';
    my $letter = C4::Letters::getletter( 'circulation', $letter_type );
    die "no letter of type '$letter_type' found. Please see sample_notices.sql" unless $letter;
    $sth->execute($borrowernumber,'0');
    my $titles = "";
    while ( my $item_info = $sth->fetchrow_hashref()) {
      push (@Ttitems, $item_info);
      my @item_info = map { $_ =~ /^date|date$/ ? format_date($item_info->{$_}) : $item_info->{$_} || '' } @item_content_fields;
      $titles .= join("\t",@item_info) . "\n";
    }
    my $ccb = try {
        my $ccbcode = C4::Circulation::GetCircControlBranch(
            pickup_branch => $Ttitems[0]{holdingbranch},
            item_homebranch => $Ttitems[0]{homebranch},
            borrower_branch => $Ttitems[0]{branchcode},
        );
        return GetBranchDetail($ccbcode);
    }
    catch {
        return {};
    };

    $letter = parse_letter( { letter         => $letter,
                              borrowernumber => $borrowernumber,
                              branchcode     => $borrower->{branchcode},
                              itemnumber     => $items[0],
                              substitute     => { count => $count,
                                                  'items.content' => $titles
                                                }
                         } );
    if ($use_tt) {
      C4::Letters::CreateTALKINGtechMESSAGE($borrowernumber,\@Ttitems,$letter->{ttcode},'1') if ($letter);
    }

    # Skip the email if an SMS number is available and Talking Tech is in use
    next if ($borrower->{smsalertnumber} && C4::Context->preference('TalkingTechEnabled'));
    if ($nomail) {
      local $, = "\f";
      print $letter->{'content'};
    }
    else {
      foreach my $transport ( @{$borrower_preferences->{'transports'}} ) {
        C4::Letters::EnqueueLetter( { letter                 => $letter,
                                      borrowernumber         => $borrowernumber,
                                      to_address => $borrower->{email},
                                      from_address => ($ccb->{branchemail} || $fromaddress || undef),
                                      message_transport_type => $transport } );
      }
    }
}

=head1 METHODS

=head2 parse_letter



=cut

sub parse_letter {
    my $params = shift;
    foreach my $required ( qw( letter borrowernumber ) ) {
        return unless exists $params->{$required};
    }

    if ( $params->{'substitute'} ) {
        while ( my ($key, $replacedby) = each %{$params->{'substitute'}} ) {
            my $replacefield = "<<$key>>";
            
            $params->{'letter'}->{title}   =~ s/$replacefield/$replacedby/g;
            $params->{'letter'}->{content} =~ s/$replacefield/$replacedby/g;
        }
    }

    C4::Letters::parseletter( $params->{'letter'}, 'borrowers',   $params->{'borrowernumber'} );

    if ( $params->{'branchcode'} ) {
        C4::Letters::parseletter( $params->{'letter'}, 'branches',    $params->{'branchcode'} );
    }
    
    if ( $params->{'biblionumber'} ) {
        C4::Letters::parseletter( $params->{'letter'}, 'biblio',      $params->{'biblionumber'} );
        C4::Letters::parseletter( $params->{'letter'}, 'biblioitems', $params->{'biblionumber'} );
    }

    if ( $params->{'itemnumber'} ) {
        C4::Letters::parseletter( $params->{'letter'}, 'items',    $params->{'itemnumber'} );
    }

    return $params->{'letter'};
}

1;

__END__
