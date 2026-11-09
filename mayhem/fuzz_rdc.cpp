// Fuzzes RenderDoc's capture-file reader through the public replay API: the RDC container
// (header, sections, zstd/lz4 streams, thumbnail) and the driver's structured-data decoder.
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <replay/renderdoc_replay.h>

// Tells librenderdoc this process is a replay program (needs -rdynamic), not a capture target.
REPLAY_PROGRAM_MARKER()

static void WalkObject(const SDObject *obj, int depth)
{
  if(depth > 64)
    return;

  volatile uint64_t sink = obj->type.byteSize + (uint64_t)obj->type.flags + (uint64_t)obj->type.basetype;
  (void)sink;
  (void)obj->name.c_str();
  (void)obj->type.name.c_str();

  size_t n = obj->NumChildren();
  for(size_t i = 0; i < n; i++)
    WalkObject(obj->GetChild(i), depth + 1);
}

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
  ICaptureFile *cap = RENDERDOC_OpenCaptureFile();

  bytebuf buf;
  buf.resize(size);
  if(size)
    memcpy(buf.data(), data, size);

  ResultDetails res = cap->OpenBuffer(buf, "rdc", NULL);
  if(!res.OK())
  {
    cap->Shutdown();
    return -1;
  }

  (void)cap->LocalReplaySupport();
  (void)cap->DriverName();
  (void)cap->RecordedMachineIdent();
  (void)cap->TimestampBase();
  (void)cap->TimestampFrequency();
  (void)cap->HasCallstacks();
  (void)cap->HasEmbeddedDependencies();
  (void)cap->HasPendingDependencies();
  (void)cap->GetPendingDependenciesNicknames();

  (void)cap->GetThumbnail(FileType::JPG, 0);
  (void)cap->GetThumbnail(FileType::PNG, 64);

  int32_t sections = cap->GetSectionCount();
  for(int32_t i = 0; i < sections; i++)
  {
    SectionProperties props = cap->GetSectionProperties(i);
    (void)props.name.c_str();
    bytebuf contents = cap->GetSectionContents(i);
    (void)contents.size();
  }

  const SDFile &sd = cap->GetStructuredData();
  for(const SDChunk *chunk : sd.chunks)
  {
    (void)chunk->metadata.chunkID;
    WalkObject(chunk, 0);
  }

  cap->Shutdown();
  return 0;
}
