begin
  require "openssl"
  require File.join(File.dirname(__FILE__), "utils.rb")
rescue LoadError
end
require "test/unit"

if defined?(OpenSSL)

class OpenSSL::TestX509Store < Test::Unit::TestCase
  def setup
    @rsa1024 = OpenSSL::TestUtils::TEST_KEY_RSA1024
    @rsa2048 = OpenSSL::TestUtils::TEST_KEY_RSA2048
    @dsa256  = OpenSSL::TestUtils::TEST_KEY_DSA256
    @dsa512  = OpenSSL::TestUtils::TEST_KEY_DSA512
    @ca1 = OpenSSL::X509::Name.parse("/DC=org/DC=ruby-lang/CN=CA1")
    @ca2 = OpenSSL::X509::Name.parse("/DC=org/DC=ruby-lang/CN=CA2")
    @ee1 = OpenSSL::X509::Name.parse("/DC=org/DC=ruby-lang/CN=EE1")
    @ee2 = OpenSSL::X509::Name.parse("/DC=org/DC=ruby-lang/CN=EE2")
  end

  def teardown
  end

  def issue_cert(*args)
    OpenSSL::TestUtils.issue_cert(*args)
  end

  def issue_crl(*args)
    OpenSSL::TestUtils.issue_crl(*args)
  end

  def test_verify
    now = Time.at(Time.now.to_i)
    ca_exts = [
      ["basicConstraints","CA:TRUE",true],
      ["keyUsage","cRLSign,keyCertSign",true],
    ]
    ee_exts = [
      ["keyUsage","keyEncipherment,digitalSignature",true],
    ]
    ca1_cert = issue_cert(@ca1, @rsa2048, 1, now, now+3600, ca_exts,
                          nil, nil, OpenSSL::Digest::SHA1.new)
    ca2_cert = issue_cert(@ca2, @rsa1024, 2, now, now+1800, ca_exts,
                          ca1_cert, @rsa2048, OpenSSL::Digest::SHA1.new)
    ee1_cert = issue_cert(@ee1, @dsa256, 10, now, now+1800, ee_exts,
                          ca2_cert, @rsa1024, OpenSSL::Digest::SHA1.new)
    ee2_cert = issue_cert(@ee2, @dsa512, 20, now, now+1800, ee_exts,
                          ca2_cert, @rsa1024, OpenSSL::Digest::SHA1.new)
    ee3_cert = issue_cert(@ee2, @dsa512, 30, now-100, now-1, ee_exts,
                          ca2_cert, @rsa1024, OpenSSL::Digest::SHA1.new)

    revoke_info = []
    crl1   = issue_crl(revoke_info, 1, now, now+1800, [],
                       ca1_cert, @rsa2048, OpenSSL::Digest::SHA1.new)
    revoke_info = [ [2, now, 1], ]
    crl1_2 = issue_crl(revoke_info, 2, now, now+1800, [],
                       ca1_cert, @rsa2048, OpenSSL::Digest::SHA1.new)
    revoke_info = [ [20, now, 1], ]
    crl2   = issue_crl(revoke_info, 1, now, now+1800, [],
                       ca2_cert, @rsa1024, OpenSSL::Digest::SHA1.new)

    assert(true, ca1_cert.verify(ca1_cert.public_key))   # self signed
    assert(true, ca2_cert.verify(ca1_cert.public_key))   # issued by ca1
    assert(true, ee1_cert.verify(ca2_cert.public_key))   # issued by ca2
    assert(true, ee2_cert.verify(ca2_cert.public_key))   # issued by ca2
    assert(true, ee3_cert.verify(ca2_cert.public_key))   # issued by ca2
    assert(true, crl1.verify(ca1_cert.public_key))       # issued by ca1
    assert(true, crl1_2.verify(ca1_cert.public_key))     # issued by ca1
    assert(true, crl2.verify(ca2_cert.public_key))       # issued by ca2

    store = OpenSSL::X509::Store.new
    assert_equal(false, store.verify(ca1_cert))
    assert_not_equal(OpenSSL::X509::V_OK, store.error)

    assert_equal(false, store.verify(ca2_cert))
    assert_not_equal(OpenSSL::X509::V_OK, store.error)

    store.add_cert(ca1_cert)
    assert_equal(true, store.verify(ca2_cert))
    assert_equal(OpenSSL::X509::V_OK, store.error)
    assert_equal("ok", store.error_string)
    chain = store.chain
    assert_equal(2, chain.size)
    assert_equal(@ca2.to_der, chain[0].subject.to_der)
    assert_equal(@ca1.to_der, chain[1].subject.to_der)

    store.purpose = OpenSSL::X509::PURPOSE_SSL_CLIENT
    assert_equal(false, store.verify(ca2_cert))
    assert_not_equal(OpenSSL::X509::V_OK, store.error)

    store.purpose = OpenSSL::X509::PURPOSE_CRL_SIGN
    assert_equal(true, store.verify(ca2_cert))
    assert_equal(OpenSSL::X509::V_OK, store.error)

    store.add_cert(ca2_cert)
    store.purpose = OpenSSL::X509::PURPOSE_SSL_CLIENT
    assert_equal(true, store.verify(ee1_cert))
    assert_equal(true, store.verify(ee2_cert))
    assert_equal(OpenSSL::X509::V_OK, store.error)
    assert_equal("ok", store.error_string)
    chain = store.chain
    assert_equal(3, chain.size)
    assert_equal(@ee2.to_der, chain[0].subject.to_der)
    assert_equal(@ca2.to_der, chain[1].subject.to_der)
    assert_equal(@ca1.to_der, chain[2].subject.to_der)
    assert_equal(false, store.verify(ee3_cert))
    assert_match(/expire/i, store.error_string)

    store = OpenSSL::X509::Store.new
    store.purpose = OpenSSL::X509::PURPOSE_ANY
    store.flags = OpenSSL::X509::V_FLAG_CRL_CHECK
    store.add_cert(ca1_cert)
    store.add_crl(crl1)   # revoke no cert
    store.add_crl(crl2)   # revoke ee2_cert
    assert_equal(true,  store.verify(ca1_cert))
    assert_equal(true,  store.verify(ca2_cert))
    assert_equal(true,  store.verify(ee1_cert, [ca2_cert]))
    assert_equal(false, store.verify(ee2_cert, [ca2_cert]))

    store = OpenSSL::X509::Store.new
    store.purpose = OpenSSL::X509::PURPOSE_ANY
    store.flags = OpenSSL::X509::V_FLAG_CRL_CHECK
    store.add_cert(ca1_cert)
    store.add_crl(crl1_2) # revoke ca2_cert
    store.add_crl(crl2)   # revoke ee2_cert
    assert_equal(true,  store.verify(ca1_cert))
    assert_equal(false, store.verify(ca2_cert))
    assert_equal(true,  store.verify(ee1_cert, [ca2_cert]))
    assert_equal(false, store.verify(ee2_cert, [ca2_cert]))

    store.flags =
      OpenSSL::X509::V_FLAG_CRL_CHECK|OpenSSL::X509::V_FLAG_CRL_CHECK_ALL
    assert_equal(true,  store.verify(ca1_cert))
    assert_equal(false, store.verify(ca2_cert))
    assert_equal(false, store.verify(ee1_cert, [ca2_cert]))
    assert_equal(false, store.verify(ee2_cert, [ca2_cert]))
  end
end

end
