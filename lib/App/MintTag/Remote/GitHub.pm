use v5.20;
package App::MintTag::Remote::GitHub;
# ABSTRACT: a remote implementation for GitHub

use Moo;
use experimental qw(postderef signatures);

with 'App::MintTag::Remote';

use LWP::UserAgent;
use URI;

use App::MintTag::Logger '$Logger';
use App::MintTag::MergeRequest;

sub ua;
has ua => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my $token = $self->api_key;

    my $ua = LWP::UserAgent->new;
    $ua->default_header(Authorization => "token $token");
    $ua->default_header(Accept => "application/vnd.github.v3+json");

    return $ua;
  },
);

sub uri_for ($self, $part, $query = {}) {
  my $uri = URI->new(sprintf(
    "%s/repos/%s%s",
    $self->api_url,
    $self->repo,
    $part,
  ));

  $uri->query_form($query);
  return $uri;
}

sub get_mrs_for_label ($self, $label, $trusted_org_name = undef) {
  my $should_filter = !! $trusted_org_name;
  my %ok_usernames;

  if ($trusted_org_name) {
    %ok_usernames = map {; $_ => 1 } $self->usernames_for_org($trusted_org_name);
  }

  # GitHub does not allow you to get pull requests by label directly, so here
  # we grab *all* the open PRs and filter the label client-side, to reduce the
  # number of HTTP requests.  (This sure would be easier if it were JMAP!)
  my @prs;

  my $url = $self->uri_for('/pulls', {
    sort => 'created',
    direction => 'asc',
    state => 'open',
    per_page => 100,
    page => 1,
  });

  while (1) {
    my ($prs, $http_res) = $self->http_get($url);

    PR: for my $pr (@$prs) {
      my $head = $pr->{head};
      my $number = $pr->{number};
      my $username = $pr->{user}{login};

      my $labels = $pr->{labels} // [];
      my $is_relevant = grep {; $_->{name} eq $label} @$labels;

      next PR unless $is_relevant;

      if ($should_filter && ! $ok_usernames{$username}) {
        $Logger->log([
          "ignoring MR %s!%s from untrusted user %s (not in org %s)",
          $self->name,
          $number,
          $username,
          $trusted_org_name,
        ]);

        next PR;
      }

      push @prs, $self->_mr_from_raw($pr);
    }

    # Now, examine the link header to see if there's more to fetch.
    my $links = $self->extract_link_header($http_res);

    last unless defined $links->{next};
    $url = $links->{next};
  }

  return @prs;
}

sub get_mr ($self, $number) {
  my $pr = $self->http_get($self->uri_for("/pulls/$number"));
  return $self->_mr_from_raw($pr);
}

sub _mr_from_raw ($self, $raw) {
  my $number = $raw->{number};

  return App::MintTag::MergeRequest->new({
    remote     => $self,
    number     => $number,
    author     => $raw->{user}->{login},
    title      => $raw->{title},
    fetch_spec => $self->name,
    refname    => "pull/$number/head",
    sha        => $raw->{head}->{sha},
    state      => $raw->{state},
  });
}

sub obtain_clone_url ($self) {
  my $repo = $self->http_get($self->uri_for(''));
  return $repo->{ssh_url};
}

sub usernames_for_org ($self, $name) {
  my $members = $self->http_get(sprintf("%s/orgs/%s/members",
    $self->api_url,
    $name,
  ));

  unless (@$members) {
    die "Hmm...we didn't find any members for the trusted org named $name!\n";
  }

  return map {; $_->{login} } @$members;
}

1;
