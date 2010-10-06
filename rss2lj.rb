#!/usr/bin/env ruby

# Copyright (c) 2008, Bem Jones-Bey <bem@jones-bey.org>
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
#     * Redistributions of source code must retain the above copyright notice,
#     this list of conditions and the following disclaimer.
#
#     * Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require 'xmlrpc/client'
require 'digest/md5'
require 'rss/1.0'
require 'rss/2.0'
require 'open-uri'
require 'yaml'
require 'iconv'

def get_rss(uri) 
  raw_rss = ''
  open(uri) do |s|
    charset = s.charset || 'iso-8859-1' # if a charset isn't specified, default to Latin-1
    raw_rss = Iconv.conv(charset, 'utf-8', s.read)
  end
  RSS::Parser.parse(raw_rss, false)
end

class LiveJournal
  def initialize(server, username, password)
    @server = XMLRPC::Client.new2(server)
    @username = username
    @password = password
  end

  class ChallengeAuth
    attr_reader :challenge, :hashed_response
    def initialize(server, password)
      @server = server
      @password = password

      response = @server.call('LJ.XMLRPC.getchallenge')
      digest = Digest::MD5.new
      digest.update(response['challenge'])

      pwmd5 = Digest::MD5.new
      pwmd5.update(@password);
      digest.update(pwmd5.hexdigest);
      @challenge = response['challenge']
      @hashed_response = digest.hexdigest
    end

    def to_params
      return {
        'ver' => '1',
        'auth_method' => 'challenge',
        'auth_challenge' => @challenge,
        'auth_response' => @hashed_response,
      }
    end
  end

  def base_params
    @challenge = ChallengeAuth.new(@server, @password)
    @challenge.to_params.merge({ 'username' => @username, })
  end

  def most_recent_update
    post_params = self.base_params.merge({
      'selecttype' => 'lastn',
      'howmany' => 1,
    })    
    response = @server.call('LJ.XMLRPC.getevents', post_params)
    events = response['events']
    if events and events.size > 0:
      return Time.parse(events[0]['eventtime'])
    else
      return nil
    end
  end

  def post(subject, body, time, backdated)
    post_params = self.base_params.merge({
      'subject' => subject,
      'event' => body,
      #'security' => 'private', # for testing
      'year' => time.year,
      'mon' => time.month,
      'day' => time.day,
      'hour' => time.hour,
      'min' => time.min,
      'props' => {
        'opt_backdated' => backdated,
        'opt_preformatted' => true,
      },
    })
    @server.call('LJ.XMLRPC.postevent', post_params)
  end
end

## MAIN
if $ARGV.length != 1 then
  puts "Usage: #{$0} config.yml"
  exit(1)
end
config_file = $ARGV[0]
config = YAML.load_file(config_file)
lj = LiveJournal.new('http://www.livejournal.com/interface/xmlrpc',
                      config['username'], config['password'])
most_recent = lj.most_recent_update
last_date = config['last_date']
config['feeds'].each do |feed|
  rss = get_rss(feed)
  rss.items.reverse.each do |item|
    # Yes, we can generally assume that a proper RSS feed will be in
    # chronological order. However, I'm paranoid, so I do lots of checking
    # below to make sure that what we get is in the proper order and that we
    # don't accidentally pick up something old.
    puts "Loading #{item.title}"
    if last_date && last_date >= item.date then
      puts "#{item.date} is older than #{last_date}, skipping"
      next
    end

    backdate = false
    if most_recent and most_recent > item.date then
      backdate = true
    else
      most_recent = item.date
    end

    body = <<END
#{item.description}
<p>Reposted from <a href="#{item.link}">#{item.link}</a></p>
END
    if config['use_posterous_hack'] then
      # XXX This is to work around some posterous specific brokenness in the rss
      # feed. Hopefully they'll fix their feed soon, and then I'll be able to
      # remove this. 
      body.sub!(/\t(<head><\/head>)?(<\/h1>)?/, '')
    end

    lj.post(item.title, body, item.date, backdate)
    if !config['last_date'] || config['last_date'] < item.date then
      config['last_date'] = item.date
      File.open(config_file, 'w') do |out|
        YAML.dump(config, out)
      end
    end
  end
end
