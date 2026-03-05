/** Copyright 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018 Roland Olbricht et al.
 *
 * This file is part of Overpass_API.
 *
 * Overpass_API is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Overpass_API is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with Overpass_API.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <fstream>
#include <iomanip>
#include <iostream>
#include <list>
#include <sstream>

#include <dirent.h>
#include <getopt.h>
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>

#include "../../expat/expat_justparse_interface.h"
#include "../../template_db/random_file.h"
#include "../core/settings.h"
#include "../frontend/output.h"
#include "node_updater.h"
#include "relation_updater.h"
#include "way_updater.h"
#include "osm_updater.h"


struct Node_Caller
{
  public:
    static void parse(FILE* osc_file) { parse_nodes_only(osc_file); }
};

struct Way_Caller
{
  public:
    static void parse(FILE* osc_file) { parse_ways_only(osc_file); }
};

struct Relation_Caller
{
  public:
    static void parse(FILE* osc_file) { parse_relations_only(osc_file); }
};

template < class Caller >
void process_source_files(const std::string& source_dir,
		          const std::vector< std::string >& source_file_names)
{
  std::vector< std::string >::const_iterator it(source_file_names.begin());
  while (it != source_file_names.end())
  {
    if ((*it == ".") || (*it == ".."))
    {
      ++it;
      continue;
    }
    FILE* osc_file(fopen((source_dir + *it).c_str(), "r"));
    if (osc_file)
    {
      //reading the main document
      Caller::parse(osc_file);

      fclose(osc_file);
    }
    else
      throw File_Error(errno, (source_dir + *it), "update_from_dir:1");
    ++it;
  }
}


int main(int argc, char* argv[])
{
  // read command line arguments
  std::string source_dir, db_dir, data_version;
  std::vector< std::string > source_file_names;
  Database_Meta_State meta;
  bool abort = false;
  unsigned int flush_limit = 16*1024*1024;

  enum { OPT_DB_DIR = 1, OPT_OSC_DIR, OPT_VERSION,
         OPT_DATA_ONLY, OPT_META, OPT_KEEP_ATTIC, OPT_FLUSH_SIZE };
  static const struct option long_options[] = {
    {"db-dir",     required_argument, nullptr, OPT_DB_DIR},
    {"osc-dir",    required_argument, nullptr, OPT_OSC_DIR},
    {"version",    required_argument, nullptr, OPT_VERSION},
    {"data-only",  no_argument,       nullptr, OPT_DATA_ONLY},
    {"meta",       no_argument,       nullptr, OPT_META},
    {"keep-attic", no_argument,       nullptr, OPT_KEEP_ATTIC},
    {"flush-size", required_argument, nullptr, OPT_FLUSH_SIZE},
    {nullptr,      0,                 nullptr, 0}
  };

  int opt;
  while ((opt = getopt_long(argc, argv, "", long_options, nullptr)) != -1)
  {
    switch (opt)
    {
      case OPT_DB_DIR:
        db_dir = optarg;
        if (!db_dir.empty() && db_dir.back() != '/')
          db_dir += '/';
        break;
      case OPT_OSC_DIR:
        source_dir = optarg;
        if (!source_dir.empty() && source_dir.back() != '/')
          source_dir += '/';
        break;
      case OPT_VERSION:
        data_version = optarg;
        break;
      case OPT_DATA_ONLY:
        meta.set_mode(Database_Meta_State::only_data);
        break;
      case OPT_META:
        meta.set_mode(Database_Meta_State::keep_meta);
        break;
      case OPT_KEEP_ATTIC:
        meta.set_mode(Database_Meta_State::keep_attic);
        break;
      case OPT_FLUSH_SIZE:
      {
        long long flush_size = atoll(optarg);
        if (flush_size == 0)
          flush_limit = std::numeric_limits< unsigned int >::max();
        else if (flush_size < 0 || flush_size > std::numeric_limits< unsigned int >::max() / (1024 * 1024))
        {
          std::cerr<<argv[0]<<": --flush-size value out of range: "<<optarg<<'\n';
          abort = true;
        }
        else
          flush_limit = static_cast< unsigned int >(flush_size * 1024 * 1024);
        break;
      }
      default:
        abort = true;
        break;
    }
  }
  if (source_dir.empty())
  {
    std::cerr<<argv[0]<<": --osc-dir is required\n";
    abort = true;
  }
  if (abort)
  {
    std::cerr<<"Usage: "<<argv[0]<<" --osc-dir=DIR"
          " [--db-dir=DIR] [--version=VER] [--meta|--keep-attic] [--flush-size=FLUSH_SIZE]\n";
    return -1;
  }

  // read file names from source directory
  DIR *dp;
  struct dirent *ep;

  dp = opendir(source_dir.c_str());
  if (dp != NULL)
  {
    while ((ep = readdir (dp)))
      source_file_names.push_back(ep->d_name);
    closedir(dp);
  }
  else
  {
    report_file_error(File_Error(errno, source_dir, "update_from_dir::opendir"));
    return -1;
  }
  std::sort(source_file_names.begin(), source_file_names.end());

  try
  {
    if (db_dir == "")
    {
      Osm_Updater osm_updater(get_verbatim_callback(), data_version, meta, flush_limit);
      get_verbatim_callback()->parser_started();

      process_source_files< Node_Caller >(source_dir, source_file_names);
      process_source_files< Way_Caller >(source_dir, source_file_names);
      process_source_files< Relation_Caller >(source_dir, source_file_names);

      osm_updater.finish_updater();
    }
    else
    {
      Osm_Updater osm_updater(get_verbatim_callback(), db_dir, data_version, meta, flush_limit);
      get_verbatim_callback()->parser_started();

      process_source_files< Node_Caller >(source_dir, source_file_names);
      process_source_files< Way_Caller >(source_dir, source_file_names);
      process_source_files< Relation_Caller >(source_dir, source_file_names);

      osm_updater.finish_updater();
    }
  }
  catch(Context_Error e)
  {
    std::cerr<<"Context error: "<<e.message<<'\n';
    return 3;
  }
  catch (const File_Error& e)
  {
    report_file_error(e);
    if (sigterm_status())
      return SIGTERM;
    return -1;
  }

  return 0;
}
