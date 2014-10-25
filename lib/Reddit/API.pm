package Reddit::API;

our $VERSION = '0.01'; ## no critic

use strict;
use warnings;
use Carp;

use LWP::UserAgent qw//;
use HTTP::Request  qw//;
use URI::Encode    qw/uri_encode/;
use JSON           qw//;
use POSIX          qw/strftime/;


require Reddit::API::Account;
require Reddit::API::Comment;
require Reddit::API::Link;
require Reddit::API::SubReddit;

#===============================================================================
# Constants
#===============================================================================

use constant DEFAULT_LIMIT      => 25;

use constant VIEW_HOT           => '/';
use constant VIEW_NEW           => '/new';
use constant VIEW_CONTROVERSIAL => '/controversial';
use constant VIEW_TOP           => '/top';
use constant VIEW_DEFAULT       => VIEW_HOT;

use constant VOTE_UP            => 1;
use constant VOTE_DOWN          => -1;
use constant VOTE_NONE          => 0;

use constant SUBMIT_LINK        => 'link';
use constant SUBMIT_SELF        => 'self';

use constant API_ME             => 0;
use constant API_INFO           => 1;
use constant API_SEARCH         => 2;
use constant API_LOGIN          => 3;
use constant API_SUBMIT         => 4;
use constant API_COMMENT        => 5;
use constant API_VOTE           => 6;
use constant API_SAVE           => 7;
use constant API_UNSAVE         => 8;
use constant API_HIDE           => 9;
use constant API_UNHIDE         => 10;
use constant API_SUBREDDITS     => 11;

use constant SUBREDDITS_HOME    => '';
use constant SUBREDDITS_MINE    => 'mine';
use constant SUBREDDITS_POPULAR => 'popular';
use constant SUBREDDITS_NEW     => 'new';
use constant SUBREDDITS_CONTRIB => 'contributor';
use constant SUBREDDITS_MOD     => 'moderator';

#===============================================================================
# Parameters
#===============================================================================

our $DEBUG    = 0;
our $BASE_URL = 'http://www.reddit.com';
our $UA       = sprintf 'Reddit::API/%f', $VERSION;

our @API;
$API[API_ME        ] = ['GET',  '/api/me'        ];
$API[API_INFO      ] = ['GET',  '/by_id/%s'      ];
$API[API_SEARCH    ] = ['GET',  '/reddits/search'];
$API[API_LOGIN     ] = ['POST', '/api/login/%s'  ];
$API[API_SUBMIT    ] = ['POST', '/api/submit'    ];
$API[API_COMMENT   ] = ['POST', '/api/comment'   ];
$API[API_VOTE      ] = ['POST', '/api/vote'      ];
$API[API_SAVE      ] = ['POST', '/api/save'      ];
$API[API_UNSAVE    ] = ['POST', '/api/unsave'    ];
$API[API_HIDE      ] = ['POST', '/api/hide'      ];
$API[API_UNHIDE    ] = ['POST', '/api/unhide'    ];
$API[API_SUBREDDITS] = ['GET',  '/reddits/%s'    ];

#===============================================================================
# Package routines
#===============================================================================

sub DEBUG {
    if ($DEBUG) {
	    my ($format, @args) = @_;
	    my $ts  = strftime "%a %b %e %H:%M:%S %Y", localtime;
	    my $msg = sprintf $format, @args;
	    chomp $msg;
	    warn sprintf("[%s] [ %s ]\n", $ts, $msg);
    }
}

sub build_query {
    my $param = shift;
    join '&', map {uri_encode($_) . '=' . uri_encode($param->{$_})} keys %$param;
}

sub subreddit {
    my $subject = shift;
    $subject =~ s/^\/r//; # trim leading /r
    $subject =~ s/^\///;  # trim leading slashes
    $subject =~ s/\/$//;  # trim trailing slashes

    if ($subject !~ /\//) {   # no slashes in name - it's probably good
        if ($subject eq '') { # front page
            return '';
        } else {              # subreddit
	        return $subject;
        }
    } else { # fail
        return;
    }
}

#===============================================================================
# Class methods
#===============================================================================

use fields (
    'modhash',      # store session modhash
    'cookie',       # store user cookie
    'session_file', # path to session file
);

sub new {
    my ($class, %param) = @_;
    my $session = $param{session_file};
    my $self    = fields::new($class);
    $self->load_session($session) if $session;
    return $self;
}

#===============================================================================
# Internal management
#===============================================================================

sub request {
    my ($self, $method, $path, $query, $post_data) = @_;
    $method = uc $method;
    $path   =~ s/^\///; # trim off leading slash

    my $request = HTTP::Request->new();
    my $url     = sprintf('%s/%s', $BASE_URL, $path);

    $url = sprintf('%s?%s', $url, build_query($query))
        if $query;

    $request->header('Cookie', sprintf('reddit_session=%s', $self->{cookie}))
        if $self->{cookie};

    if ($method eq 'POST') {
        $post_data = {} unless defined $post_data;
        $post_data->{modhash} = $self->{modhash} if $self->{modhash};
        $post_data->{uh}      = $self->{modhash} if $self->{modhash};

        $request->uri($url);
        $request->method('POST');
        $request->content_type('application/x-www-form-urlencoded');
        $request->content(build_query($post_data));
    } else {
        $request->uri($url);
        $request->method('GET');
    }

    DEBUG('%4s request to %s', $method, $url);

    my $ua  = LWP::UserAgent->new(agent => $UA, env_proxy => 1);
    my $res = $ua->request($request);

    if ($res->is_success) {
        return $res->content;
    } else {
        croak sprintf('Request error: %s', $res->status_line);
    }
}

sub json_request {
    my ($self, $method, $path, $query, $post_data) = @_;

    if ($method eq 'POST') {
        $post_data ||= {};
	    $post_data->{api_type} = 'json';
    } else {
	    $path .= '.json';
    }

    my $response = $self->request($method, $path, $query, $post_data);
    my $json     = JSON::from_json($response);

    if (ref $json eq 'HASH' && $json->{json}) {
        my $result = $json->{json};
        if (@{$result->{errors}}) {
            my @errors = map {$_->[1]} @{$result->{errors}};
            croak sprintf("Error(s): %s", join('|', @errors));
        } else {
            return $result;
        }
    } else {
        return $json;
    }
}

sub api_json_request {
    my ($self, %param) = @_;
    my $api  = $param{api}  || croak 'Expected "api"';
    my $args = $param{args} || [];
    my $data = $param{data};

    my $info   = $API[$api] || croak "Unknown API: $api";
    my ($method, $path) = @$info;
    $path = sprintf $path, @$args;

    my ($query, $post_data);
    if ($method eq 'GET') {
        $query = $data;
    } else {
        $post_data = $data;
    }

    return $self->json_request($method, $path, $query, $post_data);
}

sub is_logged_in {
    return defined $_[0]->{modhash};
}

sub require_login {
    my $self = shift;
    croak 'You must be logged in to perform this action'
        unless $self->is_logged_in;
}

sub save_session {
    my ($self, $file) = @_;
    $self->require_login;
    $self->{session_file} || $file || croak 'Expected $file';

    # Prepare session and file path
    my $session   = { modhash => $self->{modhash}, cookie => $self->{cookie} };
    my $file_path = defined $file ? $file : $self->{session_file};

    # Write out session
    open(my $fh, '>', $file_path) or croak $!;
    print $fh JSON::to_json($session);
    close $fh;

    # If session file was updated, replace the field
    $self->{session_file} = $file_path;

    return 1;
}

sub load_session {
    my ($self, $file) = @_;
    if (-f $file) {
        open(my $fh, '<', $file) or croak $!;
        my $data = do { local $/; <$fh> };
        close $fh;

        my $session = JSON::from_json($data);
        $self->{session_file} = $file;
        $self->{modhash}      = $session->{modhash};
        $self->{cookie}       = $session->{cookie};

        return 1;
    } else {
        return 0;
    }
}

#===============================================================================
# User and account management
#===============================================================================

sub login {
    my ($self, $usr, $pwd) = @_;
    !$usr && croak 'Username expected';
    !$pwd && croak 'Password expected';

    my $result = $self->api_json_request(
        api  => API_LOGIN,
        args => [$usr],
        data => { user => $usr, passwd => $pwd },
    );

    my @errors = @{$result->{errors}};

    if (@errors) {
        my $message = join(' | ', map { join(', ', @$_) } @errors);
        croak sprintf('Login errors: %s', $message);
    } else {
        $self->{modhash} = $result->{data}{modhash};
        $self->{cookie}  = $result->{data}{cookie};
    }
}

sub me {
    my $self = shift;
    $self->require_login;
    if ($self->is_logged_in) {
        my $result = $self->api_json_request(api => API_ME);
	    return Reddit::API::Account->new($self, $result->{data});
    }
}

sub list_subreddits {
    my ($self, $type) = @_;
    defined $type || croak 'Expected $type"';
    
    $self->require_login
	    if $type eq SUBREDDITS_MOD
	    || $type eq SUBREDDITS_MINE
	    || $type eq SUBREDDITS_CONTRIB;

    if ($self->is_logged_in) {
        my $result = $self->api_json_request(api => API_SUBREDDITS, args => [$type]);
        return {
            map { $_->{data}{display_name} => Reddit::API::SubReddit->new($self, $_->{data}) }
                @{$result->{data}{children}}
        };
    }
}

sub mod_subreddits     { $_[0]->require_login; return $_[0]->list_subreddits(SUBREDDITS_MOD)     }
sub my_subreddits      { $_[0]->require_login; return $_[0]->list_subreddits(SUBREDDITS_MINE)    }
sub contrib_subreddits { $_[0]->require_login; return $_[0]->list_subreddits(SUBREDDITS_CONTRIB) }

sub home_subreddits    { return $_[0]->list_subreddits(SUBREDDITS_HOME)    }
sub popular_subreddits { return $_[0]->list_subreddits(SUBREDDITS_POPULAR) }
sub new_subreddits     { return $_[0]->list_subreddits(SUBREDDITS_NEW)     }

#===============================================================================
# Finding subreddits and listings
#===============================================================================

sub info {
    my ($self, $id) = @_;
    defined $id || croak 'Expected $id';
    my $result = $self->api_json_request(api => API_INFO, args => [$id]);
    return $result;
}

sub find_subreddits {
    my ($self, $query) = @_;
    my $result = $self->api_json_request(api => API_SEARCH, data => { q => $query });
    my %subreddits = map {
        $_->{data}{display_name} => Reddit::API::SubReddit->new($self, $_->{data})
    } @{$result->{data}{children}};
    return \%subreddits;
}

sub fetch_links {
    my ($self, %param) = @_;
    my $subreddit = $param{subreddit} || '';
    my $view      = $param{view}      || Reddit::API::VIEW_DEFAULT();
    my $limit     = $param{limit}     || Reddit::API::DEFAULT_LIMIT();
    my $before    = $param{before};
    my $after     = $param{after};

    # Get subreddit and path
    $subreddit = subreddit($subreddit);
    my $path = $subreddit
        ? sprintf('/r/%s/%s', $subreddit, $view)
        : sprintf('/%s', $view);

    my @args = ('GET', $path);
    if ($before || $after || $limit) {
	    my %query;
	    $query{limit}  = $limit  if defined $limit;
	    $query{before} = $before if defined $before;
	    $query{after}  = $after  if defined $after;
	    push @args, \%query;
    }

    my $result = $self->json_request(@args);
    return {
        before => $result->{data}{before},
        after  => $result->{data}{after},
        items  => [ map {Reddit::API::Link->new($self, $_->{data})} @{$result->{data}{children}} ],
    };
}

#===============================================================================
# Submitting links
#===============================================================================

sub submit_link {
    my ($self, %param) = @_;
    my $subreddit = $param{subreddit} || '';
    my $title     = $param{title}     || croak 'Expected "title"';
    my $url       = $param{url}       || croak 'Expected "url"';

    $subreddit = subreddit($subreddit);
    $self->require_login;

    my $result = $self->api_json_request(api => API_SUBMIT, data => {
        title => $title,
        url   => $url,
        sr    => $subreddit,
        kind  => SUBMIT_LINK,
    });

    return $result->{data}{name};
}

sub submit_text {
    my ($self, %param) = @_;
    my $subreddit = $param{subreddit} || '';
    my $title     = $param{title}     || croak 'Expected "title"';
    my $text      = $param{text}      || croak 'Expected "text"';

    $subreddit = subreddit($subreddit);
    $self->require_login;

    my $result = $self->api_json_request(api => API_SUBMIT, data => {
        title => $title,
        text  => $text,
        sr    => $subreddit,
        kind  => SUBMIT_SELF,
    });

    return $result->{data}{name};
}

#===============================================================================
# Comments
#===============================================================================

sub get_comments {
    my ($self, %param) = @_;
    my $permalink = $param{permalink} || croak 'Expected "permalink"';
    my $result    = $self->{_session}->json_request('GET', $permalink);
    my $comments  = $result->[1]{data}{children};
    return [ map { Reddit::API::Comment->new($self, $_->{data}) } @$comments ];
}

sub submit_comment {
    my ($self, %param) = @_;
    my $parent_id = $param{parent_id} || croak 'Expected "parent_id"';
    my $comment   = $param{text}      || croak 'Expected "text"';

    $self->require_login;
    my $result = $self->api_json_request(api => API_COMMENT, data => {
        thing_id => $parent_id,
        text     => $comment,
    });

    my $id = $result->{data}{things}[0]{data}{id};
    return $id;
}

#===============================================================================
# Voting
#===============================================================================

sub vote {
    my ($self, $name, $direction) = @_;
    defined $name      || croak 'Expected $name';
    defined $direction || croak 'Expected $direction';
    croak 'Invalid vote direction' unless "$direction" =~ /^(-1|0|1)$/;
    $self->require_login;
    $self->api_json_request(api => API_VOTE, data => { dir => $direction, id  => $name });
}

#===============================================================================
# Saving and hiding
#===============================================================================

sub save {
    my $self = shift;
    my $name = shift || croak 'Expected $name';
    $self->require_login;
    $self->api_json_request(api => API_SAVE, data => { id => $name });
}

sub unsave {
    my $self = shift;
    my $name = shift || croak 'Expected $name';
    $self->require_login;
    $self->api_json_request(api => API_UNSAVE, data => { id => $name });
}

sub hide {
    my $self = shift;
    my $name = shift || croak 'Expected $name';
    $self->require_login;
    $self->api_json_request(api => API_HIDE, data => { id => $name });
}

sub unhide {
    my $self = shift;
    my $name = shift || croak 'Expected $name';
    $self->require_login;
    $self->api_json_request(api => API_UNHIDE, data => { id => $name });
}

1;

__END__

=pod

=head1 NAME

Reddit::API - A perl wrapper for Reddit

=head1 VERSION

Version 0.01

=head1 SYNOPSIS

    use Reddit::API;

    my $session_file = '~/.reddit';
    my $reddit       = Reddit::API->new(session_file => $session_file);

    unless ($reddit->is_logged_in) {
        $reddit->login('someone', 'secret');
        $reddit->save_session();
    }

    $reddit->submit_link(
        subreddit => 'perl',
        title     => 'Perl is still alive!',
        url       => 'http://www.perl.org'
    );

    my $links = $reddit->fetch_links(subreddit => '/r/perl', limit => 10);
    foreach (@{$links->{items}}) {
        ...
    }

=head1 DESCRIPTION

Reddit::API provides methods and simple object wrappers for objects exposed
by the Reddit API. This module handles HTTP communication, basic session
management (e.g. storing an active login session), and communication with
Reddit's external API.

For more information about the Reddit API, see L<https://github.com/reddit/reddit/wiki/API>.

=head1 CONSTANTS

	VIEW_HOT            "Hot" links feed
	VIEW_NEW            "New" links feed
	VIEW_CONTROVERSIAL  "Controversial" links feed
	VIEW_TOP            "Top" links feed
	
	VIEW_DEFAULT        Default feed if not specified (VIEW_HOT)
	DEFAULT_LIMIT       The default number of links to be retried (25)
	
	VOTE_UP             Up vote
	VOTE_DOWN           Down vote
	VOTE_NONE           "Un" vote

	SUBREDDITS_HOME     List reddits on the homepage
	SUBREDDITS_POPULAR  List popular reddits
	SUBREDDITS_NEW      List new reddits
	SUBREDDITS_MINE     List reddits for which the logged in user is subscribed
	SUBREDDITS_CONTRIB  List reddits for which the logged in user is a contributor
	SUBREDDITS_MOD      List reddits for which the logged in user is a moderator

=head1 GLOBALS

=over

=item $UA

This is the user agent string, and defaults to C<Reddit::API/$VERSION>.


=item $DEBUG

When set to true, outputs a small amount of debugging information.


=back

=head1 SUBROUTINES/METHODS

=over

=item new(session_file => ...)

Begins a new or loads an existing reddit session. If C<session_file> is
provided, it will be read and parsed as JSON. If session data is found, it
is restored. Otherwise, a new session is started.


=item is_logged_in

Returns true(ish) if there is an active login session. No attempt is made to
validate the current session against the server.


=item save_session($path)

Saves the current session to C<$path>. Throws an error if the user is not logged
in. C<$path> is only required if the Reddit::API instance was created without
the C<session_file> parameter.


=item load_session($path)

Attempts to load the session from C<$path>. When successful, returns true and
stores the session file path for future use.


=item login($usr, $pwd)

Attempts to log the user in. Throws an error on failure.


=item me

Returns a Reddit::API::Account object


=item list_subreddits($type)

Returns a list of Reddit::API::SubReddit objects for C<$type>, where C<$type>
is a C<SUBREDDITS_*> constant.


=item my_subreddits

Syntactic sugar for C<list_subreddits(SUBREDDITS_MINE)>. Throws an error if
the user is not logged in.


=item home_subreddits

Syntactic sugar for C<list_subreddits(SUBREDDITS_HOME)>. Throws an error if
the user is not logged in.


=item mod_subreddits

Syntactic sugar for C<list_subreddits(SUBREDDITS_MOD)>. Throws an error if
the user is not logged in.


=item contrib_subreddits

Syntactic sugar for C<list_subreddits(SUBREDDITS_CONTRIB)>.


=item popular_subreddits

Syntactic sugar for C<list_subreddits(SUBREDDITS_POPULAR)>.


=item new_subreddits

Syntactic sugar for C<list_subreddits(SUBREDDITS_NEW)>.


=item info($item_id)

Returns a has of information about C<$item_id>, which must be a complete name
(e.g., t3_xxxxx).


=item find_subreddits($query)

Returns a list of SubReddit objects matching C<$query>.


=item fetch_links(subreddit => ..., view => ..., limit => ..., before => ..., after => ...)

Returns a list of links from a reddit page. If C<subreddit> is specified,
the list of links is returned from the desired subreddit. Otherwise, the
links will be from the front page. C<view> specifieds the feed (e.g.
C<VIEW_NEW> or C<VIEW_HOT>). C<limit> may be used to limit the number of
objects returned, and C<before> and C<after> denote the placeholders for
slicing the feed up, just as the reddit urls themselves do. Data is returned
as a hash with three keys, I<before>, I<after>, and I<items>.


=item submit_link(subreddit => ..., title => ..., url => ...)

Submits a link to a reddit. Returns the id of the new link.


=item submit_text(subreddit => ..., title => ..., text => ...)

Submits a self-post to a reddit. Returns the id of the new post.


=item get_comments($permalink)

Returns a list ref of Reddit::API::Comment objects underneath the
the specified URL C<$permalink>. Unfortunately, this is the only
method available via the API. Comments may be more easily accessed
via the Link object, which implicitly provides the C<$permalink>
parameter.

    my $links = $reddit->fetch_links(...);
    foreach (@{$links->{items}}) {
        my $comments = $_->comments();
    }


=item submit_comment(parent_id => ..., text => ...)

Submits a new comment underneath C<parent_id>.


=item vote(item_id => ..., direction => ...)

Votes for C<item_id>. C<direction> is one of C<VOTE_UP>, C<VOTE_DOWN>,
or C<VOTE_NONE>.


=item save($item_id)

Saves C<$item_id> under the user's account.


=item unsave($item_id)

Unsaves C<$item_id> under the user's account.


=item hide($item_id)

Hides $<item_id>. Throws an error if the user does not have permission to hide
the item in question.


=item unhide($item_id)

Unhides $<item_id>. Throws an error if the user does not have permission to
unhide the item in question.


=back

=head1 INTERNAL ROUTINES

=over

=item DEBUG

When C<$Reddit::API::DEBUG> is true, acts as syntactic sugar for
warn(sprintf(@_)). Used to provided logging.


=item require_login

Throws an error if the user is not logged in.


=item subreddit

Strips slashes and leading /r from a subreddit to ensure that only
the "display name" of the subreddit is returned.


=item build_query

URI-encodes a hash of parameters into a query suitable for use in
an HTTP request. Does not include the leading '?'.


=item request

Performs a request to reddit's servers using LWP. If the user is
logged in, adds the "uh" and "modhash" parameters to POST queries
as well as adding the reddit-specified cookie value for reddit_session.


=item json_request

Wraps C<request>, configuring the parameters to perform the request
with an api_type of "json". After the request is complete, parses the
JSON result and throws and error if one is specified in the result
contents. Otherwise, returns the json data portion of the result.


=item api_json_request

Wraps C<json_request>, getting method and path from an API_CONSTANT.


=back

=head1 AUTHOR

Jeff Ober L<mailto:jeffober@gmail.com>

=head1 LICENSE

BSD license

=cut
