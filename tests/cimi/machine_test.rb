#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.  The
# ASF licenses this file to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance with the
# License.  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
# License for the specific language governing permissions and limitations
# under the License.

$:.unshift File.join(File.dirname(__FILE__))

require "test_helper.rb"

class MachineBehavior < CIMI::Test::Spec

  RESOURCE_URI = "http://schemas.dmtf.org/cimi/1/Machine"

  model :machine do |fmt|
    mcoll_uri = cep(:accept => :json).json["machines"]["href"]
    mcoll = get(mcoll_uri, :accept => :json).json
    m_url = mcoll["machines"][0]["id"]
    get m_url, :accept => fmt
  end

  it "should have the correct resourceURI", :only => :json do
    machine.wont_be_nil      # Make sure we talk to the server
    last_response.json["resourceURI"].must_equal RESOURCE_URI
  end
end
