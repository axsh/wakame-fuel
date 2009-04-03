
$:.unshift File.dirname(__FILE__) + '/../lib'
require 'rubygems'

require 'test/unit'
require 'wakame/util'

WAKAME_ROOT="#{File.dirname(__FILE__)}/.."

class TestUtilClass < Test::Unit::TestCase
  class A
    include AttributeHelper
    
    def_attribute :a, 1
    def_attribute :b, 2
    def_attribute :c, []
  end


  class B < A
    def_attribute :d, 30
    def_attribute :e, 'aaa'
    def_attribute :f
  end

  def test_attribute_helper1
    a = A.new
    assert_equal(1, a.a)
    assert_equal(2, a.b)
    assert_equal([], a.c)
    assert_equal( {:type=>'TestUtilClass::A', :a=>1, :b=>2, :c=>[]}, a.dump_attrs)


    b = B.new
    assert(b.kind_of?(AttributeHelper))
    assert_equal(1, b.a)
    assert_equal(2, b.b)
    assert_equal([], b.c)
    assert_equal(30, b.d)
    assert_equal('aaa', b.e)
    assert(b.f == nil)
    assert_equal( {:type=>'TestUtilClass::B', :a=>1, :b=>2, :c=>[], :d=>30, :e=>'aaa', :f=>nil}, b.dump_attrs)
  end



  A={23=>1, 38=>3, 2837=>1, 3727=>4, 937=>1, 184=>5, 328=>2, 8939=>1}
  def test_sorted_hash1
    s = SortedHash.new
    
    A.keys.sort_by{rand}.each { |k|
      s[k]=A[k]
    }
    
    assert_equal(A.keys.sort, s.keys)
    
    s.clear
    assert_equal([], s.keys)

  end
end
