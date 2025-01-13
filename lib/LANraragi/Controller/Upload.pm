package LANraragi::Controller::Upload;
use Mojo::Base 'Mojolicious::Controller';

use Redis;
use File::Temp qw(tempdir);
use File::Copy;
use File::Find;
use File::Basename;

use LANraragi::Utils::Generic qw(generate_themes_header is_archive get_bytelength);

use LANraragi::Utils::Logging qw(get_logger);

sub process_upload {
    my $self = shift;

    #Receive uploaded file.
    my $file     = $self->req->upload('file');
    my $catid    = $self->req->param('catid');
    my $filename = $file->filename;

    my $uploadMime = $file->headers->content_type;

    #Check if the uploaded file's extension matches one we accept
    if ( is_archive($filename) ) {

        # Move file to a temp folder (not the default LRR one)
        my $tempdir = tempdir();

        my ( $fn, $path, $ext ) = fileparse( $filename, qr/\.[^.]*/ );
        my $byte_limit = LANraragi::Model::Config->enable_cryptofs ? 143 : 255;

        # don't allow the main filename to exceed 143/255 bytes after accounting
        # for extension and .upload prefix used by `handle_incoming_file`
        $filename = $fn;
        while ( get_bytelength( $filename . $ext . ".upload" ) > $byte_limit ) {
            $filename = substr( $filename, 0, -1 );
        }
        $filename = $filename . $ext;

        my $tempfile = $tempdir . '/' . $filename;
        $file->move_to($tempfile) or die "Couldn't move uploaded file.";

        # Update $tempfile to the exact reference created by the host filesystem
        # This is done by finding the first (and only) file in $tempdir.
        find(
            sub {
                return if -d $_;
                $tempfile = $File::Find::name;
                $filename = $_;
            },
            $tempdir
        );

        # Send a job to Minion to handle the uploaded file.
        my $jobid = $self->minion->enqueue( handle_upload => [ $tempfile, $catid ] => { priority => 2 } );

        # Reply with a reference to the job so the client can check on its progress.
        $self->render(
            json => {
                operation  => "upload",
                name       => $file->filename,
                debug_name => $filename,
                type       => $uploadMime,
                success    => 1,
                job        => $jobid
            }
        );

    } else {

        $self->render(
            json => {
                operation => "upload",
                name      => $file->filename,
                type      => $uploadMime,
                success   => 0,
                error     => "Unsupported File Extension. (" . $uploadMime . ")"
            }
        );
    }
}

sub fetch_favs {
    my $logger = get_logger("Upload", "lanraragi");
    my %ehloginParams = LANraragi::Utils::Plugins::get_plugin_parameters("ehlogin");

    # Ensure required values exist
    return {} unless exists $ehloginParams{customargs};
    my $customargs = $ehloginParams{customargs};
    return {} unless ref($customargs) eq 'ARRAY' && @$customargs >= 4;

    my ($ipb_member_id, $ipb_pass_hash, $star, $igneous) = @$customargs;
    my $favorites_url = 'https://e-hentai.org/favorites.php?favcat=0&inline_set=fs_p&page=';

    # Initialize UserAgent
    my $ua = LANraragi::Plugin::Login::EHentai::get_user_agent($ipb_member_id, $ipb_pass_hash, $star, $igneous);
    $ua->transactor->name('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36');
    $ua->max_redirects(10);

    my @favorites;

    # Loop through pages
    for my $page (0) { # Adjust page range as needed
        $logger->info("Fetching favorites page: $page");
        my $res = $ua->get("$favorites_url$page")->result;

        if ($res->is_success) {
            $logger->info("Successfully fetched page $page");
            my $page_html = $res->body;

            # Parse HTML with Mojo::DOM
            my $dom = Mojo::DOM->new($page_html);

            # Find all divs with class="gl1t"
            for my $div ($dom->find('div.gl1t')->each) {
                # Get the first <a> tag href
                my $href = $div->at('a') ? $div->at('a')->attr('href') : undef;
                $href =~ s/e-hentai/exhentai/;

                # Get the <span> with class="glink" text
                my $title = $div->at('span.glink') ? $div->at('span.glink')->text : undef;

                # Get the first <img> tag src
                my $img_src = $div->at('img') ? $div->at('img')->attr('src') : undef;

                # Store the extracted data
                push @favorites, {
                    url   => $href,
                    title => $title,
                    image => $img_src,
                };

                $logger->info("Extracted favorite: URL=$href, Title=$title, Image=$img_src");
            }
        } else {
            $logger->error("Failed to fetch favorites page $page: " . $res->message);
            $logger->error("HTTP Status: " . $res->code);
            $logger->error("Response Body: " . $res->body);
        }
    }

    $logger->info("Total favorites extracted: " . scalar(@favorites));

    # Return collected favorites
    return { favorites => \@favorites };
}

sub index {

    my $self = shift;

    # Allow adding to category on direct uploads
    my @categories = LANraragi::Model::Category->get_static_category_list;

    $self->render(
        template   => "upload",
        title      => $self->LRR_CONF->get_htmltitle,
        descstr    => $self->LRR_DESC,
        categories => \@categories,
        csshead    => generate_themes_header($self),
        version    => $self->LRR_VERSION,
        %{fetch_favs()}
    );
}

1;
