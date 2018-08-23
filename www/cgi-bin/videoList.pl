#!/usr/bin/env perl

print  "Content-type:text/html\n\n";
exit if not defined $ENV{'HTTP_REFERER'};

use HTML::Tiny;
 
my $h = HTML::Tiny->new;
 
my $videoList;
fileList();

print $h->html(
  [
    $h->head([
	$h->meta({charset => 'UTF-8'}),
	$h->meta({content => 'no-cache', 'http-equiv' => 'pragma'}),
	$h->meta({content => 'no-cache', 'http-equiv' => 'cache-control'}),
	$h->title( 'Webcam videos' ),
	$h->link({href => '/styles.css', rel => 'stylesheet', type => 'text/css'})
	]),
    $h->body(
      [
	$h->open('div',{class =>'container'}),
	$h->tag('header',[$h->h1('Webcam videos')]),
        $h->open('nav'),
	$h->ul(
	  $h->li(
	    [
		eval $videoList
	    ]
	  )
	),
	$h->close('nav'),

	$h->tag('article',$h->div({style => 'text-align:center'},
		$h->tag('video',{id => 'video',width => '680',controls => '', autoplay => '' },$h->tag('source',{type => 'video/mp4'})))),

	$h->tag('footer','Copyright © Ken'),

	$h->script('function playVideo(arg) { document.getElementById("video").src = "/videos/" + document.getElementById(arg.id).getAttribute("file"); }'),

	$h->close('div'),
      ]
    )
  ]
);

exit 0;

sub fileList {

  open( DIR, "ls -ltr /var/www/html/videos | tail -20 | awk '{print \$NF}'|" ) || die "command failed: $!";
  while( <DIR> ){      
	chomp;
	my ($loc, $cam_ip, $cam_date) = split /_/;
 	$cam_date =~ s/\.mp4//g;
	$cam_date .= '.00' if $cam_date =~ /-\d{2}$/;
	$videoList .= sprintf  "\$h->a({href => '#', id => '%s', file => '%s', onclick => 'playVideo(this);'},'%s'), \$h->br,\n" , $cam_date, $_, $loc . " " . $cam_date;
  }
  close DIR;
}
