#include "../../base/SRC_FIRST.hpp"

#include "../../testing/testing.hpp"

#include "../../geometry/rect_intersect.hpp"

#include "../../platform/platform.hpp"

#include "../../map/feature_vec_model.hpp"

#include "../../indexer/data_header_reader.hpp"
#include "../../indexer/data_header.hpp"
#include "../../indexer/scales.hpp"
#include "../../indexer/feature_visibility.hpp"
#include "../../indexer/feature_processor.hpp"

#include "../../base/logging.hpp"

#include "../../std/string.hpp"
#include "../../std/algorithm.hpp"

#include "../../base/start_mem_debug.hpp"


typedef vector<pair<FeatureType, string> > feature_cont_t;

class AccumulatorBase
{
  mutable string m_dbgString;
  feature_cont_t & m_cont;

protected:
  int m_scale;

  bool is_drawable(FeatureType const & f) const
  {
    m_dbgString = f.DebugString(m_scale);
    CHECK(m_dbgString == f.DebugString(m_scale), ());

    // Feature that hasn't any geometry for m_scale returns empty DebugString().
    return (!f.IsEmptyGeometry(m_scale) && feature::IsDrawableForIndex(f, m_scale));
  }

  void add(FeatureType const & f) const
  {
    m_cont.push_back(make_pair(f, m_dbgString));
  }

public:
  AccumulatorBase(m2::RectD const & r, feature_cont_t & cont)
    : m_cont(cont)
  {
    m_scale = scales::GetScaleLevel(r);
  }

  void operator() (FeatureType const & f) const
  {
    if (is_drawable(f))
      add(f);
  }
};

class IntersectCheck
{
  m2::RectD m_rect;

  m2::PointD m_prev;
  bool m_isPrev, m_intersect;

public:
  IntersectCheck(m2::RectD const & r)
    : m_rect(r), m_isPrev(false), m_intersect(false)
  {
  }

  void operator() (CoordPointT const & p)
  {
    if (m_intersect) return;

    m2::PointD pt(p.first, p.second);
    if (m_isPrev)
    {
      m2::PointD d1 = m_prev;
      m2::PointD d2 = pt;
      m_intersect = m2::Intersect(m_rect, d1, d2);
    }
    else
      m_isPrev = true;

    m_prev = pt;
  }

  bool IsIntersect() const { return m_intersect; }
};

class AccumulatorEtalon : public AccumulatorBase
{
  typedef AccumulatorBase base_type;

  m2::RectD m_rect;

  bool is_intersect(FeatureType const & f) const
  {
    IntersectCheck check(m_rect);
    f.ForEachPointRef(check, m_scale);
    return check.IsIntersect();
  }

public:
  AccumulatorEtalon(m2::RectD const & r, feature_cont_t & cont)
    : base_type(r, cont), m_rect(r)
  {
  }

  void operator() (FeatureType const & f, uint64_t /*offset*/) const
  {
    if (is_drawable(f) && is_intersect(f))
      add(f);
  }
};

// invoke this comparator to ensure that "sort" and "compare_sequence" use equal criterion
struct compare_strings
{
  int compare(string const & r1, string const & r2) const
  {
    if (r1 < r2)
      return -1;
    if (r2 < r1)
      return 1;
    return 0;
  }
  template <class T>
  int compare(T const & r1, T const & r2) const
  {
    return compare(r1.second, r2.second);
  }
  template <class T>
  bool operator() (T const & r1, T const & r2) const
  {
    return (compare(r1, r2) == -1);
  }
};

template <class TAccumulator, class TSource>
void for_each_in_rect(TSource & src, feature_cont_t & cont, m2::RectD const & rect)
{
  cont.clear();
  TAccumulator acc(rect, cont);
  src.ForEachFeature(rect, acc);
  sort(cont.begin(), cont.end(), compare_strings());
}

class file_source_t
{
  string m_fDat;
public:
  file_source_t(string const & fDat) : m_fDat(fDat) {}

  template <class ToDo>
  void ForEachFeature(m2::RectD const & /*rect*/, ToDo toDo)
  {
    feature::ForEachFromDat(m_fDat, toDo);
  }
};

/// "test" should contain all elements from etalon
template <class TCont, class TCompare>
bool compare_sequence(TCont const & etalon, TCont const & test, TCompare comp, size_t & errInd)
{
  if (test.size() < etalon.size())
    return false;

  typedef typename TCont::const_iterator iter_t;

  iter_t i1 = etalon.begin();
  iter_t i2 = test.begin();
  while (i1 != etalon.end() && i2 != test.end())
  {
    switch (comp.compare(*i1, *i2))
    {
    case 0:
      ++i1;
      ++i2;
      break;
    case -1:
      {
        errInd = distance(etalon.begin(), i1);
        return false;
      }
    case 1:
      ++i2;
      break;
    }
  }

  return true;
}

namespace
{
  class FindOffset
  {
    pair<FeatureType, string> const & m_test;
    int m_level;

  public:
    FindOffset(int level, pair<FeatureType, string> const & test)
      : m_level(level), m_test(test)
    {}

    void operator() (FeatureType const & f, uint64_t offset)
    {
      string const s = f.DebugString(m_level);
      if (s == m_test.second)
        LOG(LINFO, (s, "Feature offset = ", offset));
    }
  };
}

UNIT_TEST(IndexForEachTest)
{
  string const path = GetPlatform().WritablePathForFile("minsk-pass" DATA_FILE_EXTENSION);

  model::FeaturesFetcher src1;
  src1.InitClassificator();
  src1.AddMap(path);

  feature::DataHeader mapInfo;
  TEST_GREATER(feature::ReadDataHeader(path, mapInfo), 0, ());

  vector<m2::RectD> rects;
  rects.push_back(mapInfo.Bounds());

  while (!rects.empty())
  {
    m2::RectD r = rects.back();
    rects.pop_back();

    feature_cont_t v1, v2;
    for_each_in_rect<AccumulatorBase>(src1, v1, r);

    file_source_t src2(path);
    for_each_in_rect<AccumulatorEtalon>(src2, v2, r);

    int const level = scales::GetScaleLevel(r);

    size_t errInd;
    if (!compare_sequence(v2, v1, compare_strings(), errInd))
    {
      src2.ForEachFeature(r, FindOffset(level, v2[errInd]));
      TEST(false, ("Failed for rect: ", r, ". Etalon size = ", v2.size(), ". Index size = ", v1.size()));
    }

    if (!v2.empty() && (level < scales::GetUpperScale()))
    {
      m2::RectD r1, r2;
      r.DivideByGreaterSize(r1, r2);
      rects.push_back(r1);
      rects.push_back(r2);
    }
  }
}
