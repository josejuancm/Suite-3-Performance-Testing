# SPDX-License-Identifier: Apache-2.0
# Licensed to the Ed-Fi Alliance under one or more agreements.
# The Ed-Fi Alliance licenses this file to you under the Apache License, Version 2.0.
# See the LICENSE and NOTICES files in the project root for more information.

"""
This module imports pipeclean-testing locusts for all scenarios
in the `tasks.pipeclean` and combines them into a single
locust which runs each scenario in order.
"""
import importlib
import os
import pkgutil
import logging

import edfi_performance_test.tasks.pipeclean
import edfi_performance_test.tasks.pipeclean.v4
import edfi_performance_test.tasks.pipeclean.v5

from typing import List
from locust import HttpUser

from edfi_performance_test.tasks.pipeclean.composite import (
    EdFiCompositePipecleanTestBase,
)
from edfi_performance_test.tasks.pipeclean.descriptors import (
    DescriptorPipecleanTestBase,
)
from edfi_performance_test.tasks.pipeclean.ed_fi_pipeclean_test_base import (
    EdFiPipecleanTestBase,
    EdFiPipecleanTaskSequence,
    EdFiPipecleanTestTerminator,
)
from edfi_performance_test.helpers.config_version import (
    exclude_endpoints_by_version,
)

logger = logging.getLogger(__name__)


class EdFiPipecleanTestMixin(object):
    min_wait = 2000
    max_wait = 9000


class PipeCleanTestUser(HttpUser):

    test_list: List[str]
    is_initialized: bool = False

    def on_start(self):
        if PipeCleanTestUser.is_initialized:
            return

        tasks_submodules = [
            name
            for _, name, _ in pkgutil.iter_modules(
                [os.path.dirname(edfi_performance_test.tasks.pipeclean.__file__)],
                prefix="edfi_performance_test.tasks.pipeclean.",
            )
        ]

        # Import modules under subfolder structures

        with os.scandir(os.path.dirname(edfi_performance_test.tasks.pipeclean.__file__)) as route:
            subFolders = [folder.name for folder in route if folder.is_dir()]
        for sub in subFolders:
            path = os.path.join(os.path.dirname(edfi_performance_test.tasks.pipeclean.__file__), sub)
            for dirpath, dirnames, fNames in os.walk(path):
                for fNames in list(filter(lambda f: f.endswith('.py') and not f.startswith("__"), fNames)):
                    tasks_submodules.append("edfi_performance_test.tasks.pipeclean." + sub + "." + fNames.replace(".py", ""))

        # exclude not present endpoints

        tasks_submodules = exclude_endpoints_by_version(str(PipeCleanTestUser.host), tasks_submodules)

        for mod_name in tasks_submodules:
            importlib.import_module(mod_name)

        # Collect *PipecleanTest classes and append them to
        # EdFiPipecleanTaskSequence.tasks
        for subclass in EdFiPipecleanTestBase.__subclasses__():
            if (
                subclass != EdFiCompositePipecleanTestBase
                and subclass != DescriptorPipecleanTestBase
            ):
                EdFiPipecleanTaskSequence.tasks.append(subclass)

        # Add composite pipeclean tests
        if os.environ["PERF_DISABLE_COMPOSITES"].lower() != "true":
            for subclass in EdFiCompositePipecleanTestBase.__subclasses__():
                EdFiPipecleanTaskSequence.tasks.append(subclass)
        else:
            logger.info("Composites tests have been disabled")

        # Add descriptor pipeclean tests
        for descriptorSubclass in DescriptorPipecleanTestBase.__subclasses__():
            EdFiPipecleanTaskSequence.tasks.append(descriptorSubclass)

        # If a list of tests were given, filter out the rest
        if PipeCleanTestUser.test_list:
            EdFiPipecleanTaskSequence.tasks = list(
                filter(
                    lambda x: (x.__name__ in PipeCleanTestUser.test_list),
                    EdFiPipecleanTaskSequence.tasks,
                )
            )

        EdFiPipecleanTaskSequence.tasks.append(EdFiPipecleanTestTerminator)

        # assign all pipeclean tasks to HttpUser
        self.tasks.append(EdFiPipecleanTaskSequence)

        PipeCleanTestUser.is_initialized = True
