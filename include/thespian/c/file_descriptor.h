#pragma once

// NOLINTBEGIN(modernize-use-trailing-return-type)
#ifdef __cplusplus
extern "C" {
#endif

struct thespian_file_descriptor_handle;
struct thespian_file_descriptor_handle *
thespian_file_descriptor_create(const char* tag, int fd);
int thespian_file_descriptor_wait_write(struct thespian_file_descriptor_handle *);
int thespian_file_descriptor_wait_read(struct thespian_file_descriptor_handle *);
int thespian_file_descriptor_cancel(struct thespian_file_descriptor_handle *);
void thespian_file_descriptor_destroy(struct thespian_file_descriptor_handle *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type)
