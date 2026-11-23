# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "digest"
require "fileutils"
require "open3"

module TebakoDotnetBuilder
  # Download + verification (the factories' curl idiom — factory build
  # tooling, never a shipped artifact): a pin mismatch is a hard named
  # error after a bounded retry (a poisoned CDN edge or a
  # truncated-but-200 body must not fail the leg on first strike — the
  # openjdk grammar — and a mismatched download never rides a reuse
  # guard into the next attempt).
  module Fetcher
    ATTEMPTS = 3

    module_function

    def sha256_of(path)
      Digest::SHA256.file(path).hexdigest
    end

    def sha512_of(path)
      Digest::SHA512.file(path).hexdigest
    end

    # Fetch url to dest (reusing an already-verified dest across calls)
    # and verify the recorded sha256. Returns dest.
    def download(url, dest, sha256:)
      attempt = 1
      loop do
        fetch(url, dest) unless File.file?(dest) && sha256_of(dest) == sha256
        return dest if sha256_of(dest) == sha256

        FileUtils.rm_f(dest)
        if attempt >= ATTEMPTS
          raise TebakoDotnetBuilder::Error.new(
            "#{dest} fails sha256 verification after #{ATTEMPTS} downloads " \
            "(the recorded pin is #{sha256}; url #{url}) — a supply-chain event is reported, never worked around", 102
          )
        end
        attempt += 1
        warn "::warning::#{dest} sha256 mismatch — re-downloading (attempt #{attempt}/#{ATTEMPTS})"
      end
    end

    # Body of an HTTPS URL (the contract gate's parity arm): bounded
    # retry, the body on success, a named error on exhaustion.
    def read_url(url, code: 1)
      attempt = 1
      begin
        out, err, status = Open3.capture3("curl", "-fsSL", "--max-time", "30", url)
        return out if status.success?

        raise TebakoDotnetBuilder::Error.new("curl exited #{status.exitstatus}: #{err.strip}", code)
      rescue TebakoDotnetBuilder::Error, Errno::ENOENT => e
        raise if attempt >= ATTEMPTS

        attempt += 1
        warn "::warning::read of #{url} failed (#{e.message}) — retrying (attempt #{attempt}/#{ATTEMPTS})"
        sleep(attempt * 2)
        retry
      end
    end

    def fetch(url, dest)
      FileUtils.mkdir_p(File.dirname(dest))
      out, err, status = Open3.capture3("curl", "-fsSL", "--retry", "3", "-o", dest, url)
      return if status.success?

      raise TebakoDotnetBuilder::Error.new("download of #{url} failed: #{err.strip} #{out.strip}".strip, 102)
    end
  end
end
