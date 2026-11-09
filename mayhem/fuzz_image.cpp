// Fuzzes RenderDoc's image loaders (DDS, EXR, HDR, PNG, JPG, BMP, TGA via the image-viewer
// replay driver) through the public replay API.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <replay/renderdoc_replay.h>

// Tells librenderdoc this process is a replay program (needs -rdynamic), not a capture target.
REPLAY_PROGRAM_MARKER()

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
  GlobalEnvironment env;
  env.enumerateGPUs = false;
  RENDERDOC_InitialiseReplay(env, rdcarray<rdcstr>());
  // InitialiseReplay opens a process-wide disk log that every rejected input appends to; close it.
  RENDERDOC_SetDebugLogFile("");
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  const char *tmpdir = getenv("TMPDIR");
  if(!tmpdir || !*tmpdir)
    tmpdir = "/tmp";

  char path[4096];
  snprintf(path, sizeof(path), "%s/rdoc_image_XXXXXX", tmpdir);
  int fd = mkstemp(path);
  if(fd < 0)
    return -1;

  size_t off = 0;
  while(off < size)
  {
    ssize_t w = write(fd, data + off, size - off);
    if(w <= 0)
      break;
    off += (size_t)w;
  }
  close(fd);

  int ret = -1;

  ICaptureFile *cap = RENDERDOC_OpenCaptureFile();

  if(cap->OpenFile(path, "", NULL).OK())
  {
    rdcpair<ResultDetails, IReplayController *> opened = cap->OpenCapture(ReplayOptions(), NULL);

    if(opened.first.OK() && opened.second)
    {
      IReplayController *ctrl = opened.second;

      const rdcarray<TextureDescription> &textures = ctrl->GetTextures();
      for(const TextureDescription &tex : textures)
      {
        Subresource sub;
        bytebuf texdata = ctrl->GetTextureData(tex.resourceId, sub);
        (void)texdata.size();
      }

      ctrl->Shutdown();
      ret = 0;
    }
    else
    {
      // The image is decoded before the GPU proxy driver is created, so on a machine with no GPU these
      // codes mean the decoders accepted the file; any other code means they rejected it.
      switch(opened.first.code)
      {
        case ResultCode::APIUnsupported:
        case ResultCode::APIInitFailed:
        case ResultCode::APIHardwareUnsupported: ret = 0; break;
        default: break;
      }
    }
  }

  cap->Shutdown();
  unlink(path);
  return ret;
}
