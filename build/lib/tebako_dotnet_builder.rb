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

# Tebako .NET runtime builder (tebako-runtime-dotnet)
#
# Build tooling that produces tebako .NET runtime pairs from Microsoft's
# PRISTINE per-RID .NET SDK archives (dotnet-sdk-<version>-<rid>.tar.gz /
# .zip, verified against the sha256 pins in versions.yml — Microsoft
# publishes the compiled builds; this factory REPACKS them, the
# node/openjdk grammar, never a source build). The pair is the spec-29
# wrapper exe (tebako-runtime-launcher, consumed from the pinned
# tamatebako/tebako release — the driver cannot be linked into bytes
# tebako did not compile) plus the env image (the SDK tree pruned to the
# declared scope, the layout card, the tier-1 manifest), visibility:
# exec-cache — the openjdk shape. See docs/build-chain.md.
module TebakoDotnetBuilder
  # Autoloads use absolute paths so the library loads regardless of the
  # caller's $LOAD_PATH.
  autoload :Builder,       File.expand_path("tebako_dotnet_builder/builder", __dir__)
  autoload :Contract,      File.expand_path("tebako_dotnet_builder/contract", __dir__)
  autoload :Error,         File.expand_path("tebako_dotnet_builder/error", __dir__)
  autoload :Fetcher,       File.expand_path("tebako_dotnet_builder/fetcher", __dir__)
  autoload :ImageBuilder,  File.expand_path("tebako_dotnet_builder/image_builder", __dir__)
  autoload :Pins,          File.expand_path("tebako_dotnet_builder/pins", __dir__)
  autoload :Platform,      File.expand_path("tebako_dotnet_builder/platform", __dir__)
  autoload :Toolchain,     File.expand_path("tebako_dotnet_builder/toolchain", __dir__)
end
