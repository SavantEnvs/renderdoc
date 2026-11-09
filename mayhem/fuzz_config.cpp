// Fuzzes qrenderdoc's UI configuration loader (PersistantConfig::Load) with the bytes of a UI.config file,
// the JSON the GUI reads from the user's profile at start-up. The real qrenderdoc sources are linked in,
// not a copy: the JSON parse, the per-setting conversion and the shader-tool post-processing.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include <QCoreApplication>
#include <QString>
#include "Code/Interface/PersistantConfig.h"

// Tells librenderdoc this process is a replay program (needs -rdynamic), not a capture target.
REPLAY_PROGRAM_MARKER()

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
  static int argc = 1;
  static char arg0[] = "fuzz_config";
  static char *argv[] = {arg0, NULL};
  static QCoreApplication *app = new QCoreApplication(argc, argv);
  (void)app;

  GlobalEnvironment env;
  env.enumerateGPUs = false;
  RENDERDOC_InitialiseReplay(env, rdcarray<rdcstr>());
  // InitialiseReplay opens a process-wide disk log; close it.
  RENDERDOC_SetDebugLogFile("");
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  const char *tmp = getenv("TMPDIR");
  char path[4096];
  snprintf(path, sizeof(path), "%s/fuzz_config.XXXXXX", tmp && *tmp ? tmp : "/tmp");

  int fd = mkstemp(path);
  if(fd < 0)
    return -1;

  size_t off = 0;
  while(off < size)
  {
    ssize_t n = write(fd, data + off, size - off);
    if(n <= 0)
      break;
    off += (size_t)n;
  }
  close(fd);

  int ret = 0;
  {
    PersistantConfig cfg;
    // false: the file is not a readable UI config (empty, not JSON, or no/old "rdocConfigData" tag)
    if(!cfg.Load(rdcstr(path)))
      ret = -1;
  }

  unlink(path);
  return ret;
}
